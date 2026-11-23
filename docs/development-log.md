# Журнал разработки

Исторический документ: как исследовался проект, какие решения принимались и какие
дефекты находились при приёмке. **Текущее** состояние описано в
[корневом README](../README.md), а справочные материалы — в
[карте документации](README.md).

Этот файл — преемник удалённого `PLAN.md`: чек-листы с промежуточными цифрами
заменены итоговыми результатами, устаревшие пункты (вроде «первый пуш ещё не сделан»)
убраны.

## 1. Исходное расследование

Проверено на машине разработки в начале проекта:

| Вопрос | Ответ |
| --- | --- |
| Версия opencode | `1.15.11` (V1 CLI, нет подкоманд `api` / `service`) |
| Где лимиты | **Не в БД** — официальный API подписки `GET https://opencode.ai/inference/go/v1/usage` |
| Ключ Go | `~/.local/share/opencode/opencode.db` → `credential`, строка `integration_id='opencode-go' AND active=1`, JSON-поле `key` |
| Активность | `session_message` (`type='assistant'`), `time_created` в мс, `tokens`, `cost`, `model` |
| Ловушка | Таблица `part` (`step-finish`) дублирует `session_message` (2236 пересечений, равные суммы `cost`) — чтение удвоило бы счёт |
| Приватность | `data.content` содержит промпты → не читать и не логировать |
| Сеть | Системный HTTPS-прокси `127.0.0.1:1082` задан через `scutil`, **не через env**; `curl` без `-x` не коннектится |
| Окружение | macOS 27.2.1, Swift 6.4.2, только CommandLineTools; `sqlite3.h` лишь в sysroot → shim-модуль `CSQLite3` |

### Семантика лимитов Go

- `rolling` (5 ч) = 20 % месячного allowance; окно стартует с первого запроса и длится 5 ч; до старта `resetsAt = now + 5 ч`.
- `weekly` = 50 %; сброс в пн 00:00 UTC.
- `monthly` = 100 %; сброс в начале оплаченного периода.
- `status: rate-limited` — лимит исчерпан; `401` — невалидный ключ; `403 EntitlementError` — нет подписки.

## 2. Ключевые решения

1. **SwiftUI без внешних зависимостей.** SwiftPM, только системные фреймворки. Прокси читается явно через `SCDynamicStoreCopyProxies` с fallback на `HTTPS_PROXY`.
2. **Разделённые источники данных.** Лимиты — из Go API; активность — из локального V2 API с fallback на SQLite. Истории в удалённом API нет.
3. **Ключ не копируется в настройки.** Читается из `opencode.db` при каждом опросе; fallback `OPENCODE_GO_KEY` → Keychain. Ключ никогда не логируется.
4. **Токены — основная метрика активности**, деньги вторичны: большинство моделей в данных бесплатные (`cost = 0`).
5. **Четыре таргета:** `CSQLite3` → `OpenCodeLimitsCore` (тестируемая библиотека) → `OpenCodeLimits` (SwiftUI) + `OpenCodeLimitsTests`.
6. **Иконка в трее рисуется кодом** (`NSImage`, два кольца), `LSUIElement = true` — без иконки в Dock.
7. **Опрос:** при запуске, по таймеру (60 с по умолчанию), при открытии окна; тяжёлая активность — не чаще 5 мин.
8. **Выбор метра для иконки** (`TrayMeter`: 5 ч / Неделя / Месяц / Авто), по умолчанию 5 ч; влияет только на иконку.

Эволюция двух пунктов: п. 2起初 означал «активность из SQLite», позже заменён на API-first
(раунд 4); п. 6起初 использовал `MenuBarExtra`, позже заменён на `NSStatusItem` ради
разделения левого/правого клика (раунд 6).

## 3. Поиск API активности

**Первый вывод «API нет» был ошибкой:** искался удалённый Console API, а нужный
оказался локальным V2 API OpenCode Desktop 2.3.0
(`/Applications/OpenCode.app` → `…/cli/2.3.0-arm64/opencode-cli serve --service`).

| Эндпоинт | Результат |
| --- | --- |
| `GET /api/experimental/session/stats` | готовые агрегаты: `activity[]`, `models[]`, `tokens`, `cost`, `steps`, `sessions`, `activeDays`, `streak` |
| `…?from=<ms>&to=<ms>&tools=none` | период 7/30/90/всё время, ответ в `.data` |
| `GET /api/session` | список сессий с `title`, `model`, `tokens`, `time` |
| `GET /api/experimental/usage/limits` | `data: null` на этой машине → лимиты остаются на прямом Go API |
| Авторизация | `Basic base64("opencode:" + password)` из `~/.config/opencode/service.json`; `base64(":password")` даёт 401 |
| Discovery порта | `opencode-cli service status` → `http://127.0.0.1:<порт>` |

Публичный Console API histories действительно не отдаёт (проверено ~30 путями с рабочим
ключом):

| Источник | Результат |
| --- | --- |
| `GET /inference/go/v1/usage` | 200, но только 3 текущих метра без истории |
| `opencode.allowance` в ответе inference | $ за запрос, только в момент ответа |
| `GET /console/api/v1/models` | 200 — каталог моделей |
| `/console/api/v1/{usage*,activity*,logs,stats,billing,budgets,members,me}`, `/inference/go/v1/usage/history` | **404** |
| Console UI «Activity → Usage» + CSV-экспорт | внутренние endpoint'ы cookie-сессии, с API-ключом недоступны |
| Permission `Usage: Read` в документации | упомянут, но рабочий REST-путь не описан |

**Итог:** `ActivityService` стал API-primary с молчаливым SQLite-fallback,
`ActivitySnapshot.source` показывает источник в UI.

## 4. SQL-эталон для сверки

Прямой запрос **только** к `session_message` (без `part`):

| Метрика | Снимок 2026-11-23 |
| --- | --- |
| input | 3 110 813 |
| output | 240 051 |
| reasoning | 87 635 |
| cache read | 22 589 888 |
| cache write | 0 |
| **total tokens** | **26 028 387** |
| cost, USD | 0.181899 |

БД живая, цифры растут по мере работы. Сверка делалась сразу после `make smoke` без
временного разрыва: совпадение было точь-в-точь. Если totals окажутся ~в 2 раза выше
эталона — значит случайно прочитана и таблица `part`. Из-за почти пустой 30-дневной
истории (данные в основном январь–июнь 2026) появился переключатель периода.

## 5. Сон и энергопотребление

Приложение **не препятствует засыпанию Mac**: в коде нет `IOPMAssertionCreate*`,
`NSProcessInfo.beginActivity`, `caffeinate`, `disableSuddenTermination`,
`NSBackgroundActivityScheduler`, background `URLSession` и `Info.plist`-ключей,
влияющих на сон. `pmset -g assertions` подтвердил: сон удерживают Chrome (аудио),
`coreaudiod`, `bluetoothd`, `powerd`, `mds` — нашего процесса там нет.

macOS засыпает по отсутствию пользовательского ввода; таймеры и сеть приложения не
считаются активностью. Во сне `Timer` приостанавливается, при пробуждении даёт одно
догоняющее срабатывание. В раунде 6 добавлены `NSWorkspace.willSleepNotification` /
`didWakeNotification` и адаптивные интервалы для батареи / Low Power Mode.

## 6. Риски и митигации

| Риск | Митигация |
| --- | --- |
| `modulemap` не найдёт `sqlite3.h` | shim с `<sqlite3.h>` + sysroot SDK |
| Схема БД opencode изменится | чтение через `json_extract` с `COALESCE`, пустой результат вместо краша |
| Ключ обновился / подписка кончилась | ключ читается заново каждый опрос; 401/403 показываются баннером |
| Прокси отключился | fallback на env и обычную конфигурацию, таймаут 15 с |
| Уведомления без `.app` | `UNUserNotificationCenter` + `NSSound.beep()` при отсутствии bundle |
| Go API экспериментальный | ошибки не роняют приложение, сохраняется последний удачный снимок |
| Локальный V2 сервис не запущен | молчаливый fallback на SQLite |
| ad-hoc подпись | для распространения нужен Developer ID + нотаризация (секреты Apple) |

## 7. История раундов

| Раунд | Что сделано | Найдено и исправлено при приёмке |
| --- | --- | --- |
| 1 | Каркас: SwiftPM-таргеты, SwiftUI-меню-бар, Core-модели и сервисы, Go usage API, SQLite | — |
| 2 | Раннер проверок без XCTest, периоды активности 7/30/90/«Всё время» | нет `XCTest.framework`; нет `SwiftUIMacros` (`@State`); `ActivityView` зашит на 30 дней; `isCritical`/цвет иконки рассинхронизированы |
| 3 | `TrayMeter` — выбор окна для иконки (по умолчанию 5 ч) | — |
| 4 | Активность из локального V2 API + fallback на SQLite | `/api/session` отдавал всю историю (44 сессии) вместо выбранного окна → фильтр по `time.updated` |
| 5 | Второе кольцо иконки — отсчёт до сброса 5-часового окна | цифра `100` перекрывала внутреннее кольцо → динамический шрифт; ошибка в ТЗ (1 ч = 1/5, не 1/6) |
| 6 | Энергосбережение, меню правого клика, `NSStatusItem` | «раз в 0 мин» при интервале 30 с; `make run` падал в `UNUserNotificationCenter` без bundle |
| 7 | Новая компоновка окна настроек 480×640, `ScrollView`, перенос подписей | обрезанная нижняя секция, «…» в длинных текстах |
| 8 | `.gitignore`, аудит секретов, README на русском | — |
| 9 | 8 документов в `docs/` | 74 ссылки проверены, битых 0 |
| 10 | GitHub Actions: сборка, тесты, ZIP-артефакт, Release по тегу | — |
| 11 | Hotfix CI: `main.swift` → `OpenCodeLimitsApp.swift` | `@main` запрещён в модуле с top-level code; локально скрывал кэш `.build/` |

Число проверок росло по раундам: 103 → 116 → 146 → 155 → 179 (`make test`),
`make smoke` — 183 на момент фиксации.

## 8. Текущее состояние

- Репозиторий: `https://github.com/saneksa/opencode-limits.git`, ветка `main`.
- CI: `.github/workflows/build.yml` на `macos-latest`, последний прогон — `success`
  (все 9 шагов), артефакт `OpenCodeLimits-macos-<sha>` (~361 КБ).
- `make test` — **179 passed, 0 failed**; `make smoke` — **183 passed, 0 failed**.
- `.app` — 1.4 МБ, Mach-O arm64, ad-hoc подпись, `LSUIElement = true`.
- Секретов в репозитории нет: ключи, пароли и БД лежат вне проекта.

См. также: [Архитектура](architecture.md), [Источники данных](data-sources.md),
[Сборка и тесты](build-and-test.md), [Безопасность](security.md).
