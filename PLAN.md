# План проекта: OpenCode Limits Monitor

Десктопное приложение для macOS в menu bar, показывающее расход подписки **OpenCode Go**:
три окна (5 часов / неделя / месяц), экран активности, уведомления о порогах.

## 1. Что выяснено (проверено на этой машине)

| Вопрос | Ответ |
| --- | --- |
| Версия opencode | `1.15.11` (V1 CLI, нет подкоманд `api` / `service`) |
| Где лимиты | **Не в БД.** Официальный API Go: `GET https://opencode.ai/inference/go/v1/usage` |
| Ключ | `~/.local/share/opencode/opencode.db` → таблица `credential`, строка `integration_id='opencode-go' AND active=1`, поле `value` = `{"type":"key","key":"oc_sk_…"}` |
| Живой ответ API | `rolling 8% / weekly 3% / monthly 49%`, `status: ok`, `resetsAt` ISO8601 |
| Активность | `session_message` (`type='assistant'`), 622 строки, у каждой `time_created` (ms), `tokens`, `cost`, `model` |
| Ловушка | Таблица `part` (`step-finish`) **дублирует** `session_message` (2236 пересечений, суммы `cost` равны `0.1819`). Читать её нельзя — будет двойной счёт |
| Приватность | `data.content` содержит промпты → не читать, не логировать |
| Сеть | Системный HTTPS-прокси `127.0.0.1:1082` задан через `scutil`, **не через env**. `curl` без `-x` не коннектится |
| Сборка | macOS 27.2.1, Swift 6.4.2, SDK CLT. `sqlite3.h` есть только в sysroot → shim-модуль `CSQLite3` |

### Семантика лимитов Go (из документации)
- `rolling` (5 ч) = 20% месячного allowance; окно стартует с первого запроса и длится 5 ч; до старта `resetsAt = now + 5h`.
- `weekly` = 50%; сброс в пн 00:00 UTC.
- `monthly` = 100%; сброс в начале платящего периода.
- `status: rate-limited` — лимит исчерпан; `401` — невалидный ключ; `403 EntitlementError` — нет подписки.

## 2. Решения

1. **SwiftUI без зависимостей** (выбор пользователя). SwiftPM, только системные фреймворки.
   `URLSession` подхватывает системный прокси, но для надёжности прокси читается явно через `SCDynamicStoreCopyProxies`.
2. **Два источника данных**: Go API — для трёх счётчиков; локальная БД (read-only) — для истории/активности.
   Истории в Go API нет, поэтому «Активность» считается локально.
3. **Ключ не копируется в настройки приложения**: читается из `opencode.db` на каждый опрос;
   fallback — `OPENCODE_GO_KEY`, затем Keychain (для ручного ввода). Ключ никогда не логируется.
4. **Метрика активности — токены**, деньги вторичны: в данных пользователя большинство моделей бесплатные (`cost = 0`).
5. **Разделение на таргеты**: `CSQLite3` (system library) → `OpenCodeLimitsCore` (модели + сервисы, тестируемо)
   → `OpenCodeLimits` (SwiftUI executable) + `OpenCodeLimitsTests`. Позволяет тестировать парсинг/агрегацию без GUI.
6. **Tray**: `MenuBarExtra(..., .menuBarExtraStyle(.window))` + программно отрисованный `NSImage`
   (кольцо прогресса + процент «самого горячего» окна). `LSUIElement = true` → нет иконки в Dock.
7. **Опрос**: сразу при запуске, по таймеру (по умолчанию 60 с), при открытии окна.
   Тяжёлую агрегацию активности — не чаще раза в 5 минут.
8. **Выбор метра для иконки трея** (раунд 3): изначально иконка показывала
   `usage.worst` (максимальный процент), из-за чего при `monthly=50%` в трее
   всегда был месяц. Добавлен `TrayMeter` (`rolling` / `weekly` / `monthly` /
   `auto`) + `UsageSnapshot.meter(for:)`, настройка `AppDefaultsKey.trayMeter`,
   **по умолчанию `rolling` (5 часов)**; `auto` сохраняет прежнее поведение.
   Настройка влияет ТОЛЬКО на иконку: три карточки в попапе и уведомления
   по-прежнему показывают все три окна. Смена настройки обновляет иконку мгновенно,
   без сетевого опроса.

## 3. Архитектура

```
Package.swift                     контракт сборки (4 таргета, без внешних пакетов)
Sources/CSQLite3/                 module.modulemap + shim.h → import CSQLite3
Sources/OpenCodeLimitsCore/
  Models/Usage.swift              MeterStatus, UsageMeter, MeterRow, UsageSnapshot, UsageError
  Models/Activity.swift           UsageEvent, ActivityBucket, ModelBucket, SessionSummary, ActivitySnapshot
  Services/SQLite.swift           read-only обёртка над sqlite3
  Services/CredentialStore.swift  opencode.db → env → Keychain
  Services/ProxyProvider.swift    SCDynamicStoreCopyProxies → connectionProxyDictionary
  Services/GoUsageService.swift   URLSession → /inference/go/v1/usage
  Services/ActivityService.swift  session_message + session_v2 + project → агрегаты
Sources/OpenCodeLimits/
  OpenCodeLimitsApp.swift / App/  @main App, AppState, Settings, Notifier
  Views/                         MenuBar, UsageMeter, Activity (Swift Charts), Settings, TrayIcon
Tests/OpenCodeLimitsTests/       парсинг JSON, маппинг 401/403, агрегация
Makefile / Info.plist / README.md
```

Публичный контракт `OpenCodeLimitsCore` зафиксирован в ТЗ обоим агентам; он же дублируется в их файлах.

## 4. Чек-лист приёмки (планировщик)

- [x] `swift build --target OpenCodeLimitsCore` — чисто
- [x] `swift build -c release` — **Build complete!** (только безобидные ld-варнинги CLT о search paths)
- [x] Контракт совпадает: все `public` символы на месте, UI не определяет свои типы данных
- [x] Нет обращений к таблице `part` и к `$.content`; `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)`
- [x] Нет `print`/`NSLog` в `Sources/`; ключ и `Authorization` не логируются
- [x] UI не использует макросы SwiftUI (`@State`, `#Preview`, `@Environment(\.openSettings)`) —
      в CLT отсутствует `SwiftUIMacros` plugin, агент обошёл через `@StateObject`
- [x] `make test` — **103 passed, 0 failed** (dependency-free runner)
- [x] `make smoke` — **107 passed, 0 failed**; живой API → `rolling=14, weekly=5, monthly=50`
- [x] `make app` — `plutil OK`, `codesign valid`, arm64 Mach-O, `LSUIElement=true`
- [x] Totals совпали с SQL-эталоном **точь-в-точь**: `199 / 13 583 218 / $0.00`
      (сверка сделана сразу после smoke, без временно́го разрыва)
- [x] Период 7/30/90/Всё время + помесячный график
- [x] Цвет иконки согласован с `warnThreshold` через `meter.isCritical`
- [x] `make run` исправлен: `swift run OpenCodeLimits` (иначе «multiple executable products»)
- [x] README приведён в соответствие (раннер без XCTest, `make smoke`, периоды)

### Раунд 5 — второе кольцо: откат 5-часового лимита

- [x] `UsageMeter.rollingWindowFraction(now:)` + `AppConfig.rollingWindowDuration` (5 ч) +
      `AppDefaultsKey.trayCountdown`; 9 новых проверок на clamp/nil
- [x] Иконка 22×22 pt: внешнее кольцо (r 8.6) = выбранный лимит, внутреннее (r 6.0, `systemTeal`) =
      убывающая дуга «сколько осталось до сброса rolling» (1 = 5 ч, 0 = сброс)
- [x] Внутреннее кольцо ВСЕГДА от `usage.rolling`, даже когда выбран Месяц
- [x] Тик раз в 30 с (`clock = Date()`), без `refresh()` и без сети; тумблер
      «Кольцо отката 5 ч» в настройках, по умолчанию вкл.
- [x] **Дефект приёмки исправлен:** при `100%` трёхзначная цифра перекрывала внутреннее
      кольцо — добавлен динамический шрифт (1 знак 8.0 / 2 — 7.2 / 3 — 5.8 pt)
      и внутренний радиус увеличен до 6.0 pt
- [x] Ошибка в ТЗ планировщика: 1 ч из 5 ч = **1/5 (0.2)**, а не 1/6 — агент
      реализовал по формуле и написал корректный тест
- [x] `swift build -c release`, `make test` — **155 passed, 0 failed**,
      `make smoke` — **159 passed, 0 failed**, `make app` — подпись валидна, аудит чист

### Раунд 4 — активность из локального V2 API

- [x] `LocalAPIService`: discovery (`opencode-cli service status`), Basic `opencode:<password>`,
      localhost без системного прокси, таймауты, кеш URL, re-discovery при смене порта
- [x] `GET /api/experimental/session/stats?from=&to=&tools=none` + `GET /api/session` →
      `ActivitySnapshot` (`daily` с токенами/$, `monthly`, `models`, `sessions`, totals)
- [x] `ActivitySource` + `ActivitySnapshot.source`, API-primary с молчаливым fallback на SQLite
- [x] В UI подпись «Источник: API OpenCode / Локальная БД» и плитка «Шагов» при `.api`
- [x] Пароль / Authorization / ключ нигде не логируются
- [x] **Дефект приёмки исправлен:** `/api/session` отдаёт всю историю (44 сессии), а `stats` —
      только выбранное окно (3 за 30 дней). Сессии теперь фильтруются по `time.updated`,
      а токены относятся к дате последней активности, а не к дате создания.
      До правки `events=44`, после — `events=3`.
- [x] `swift build -c release` — Build complete; `make test` — **146 passed, 0 failed**;
      `make smoke` — **150 passed, 0 failed**, `source=api`; `make app` — `plutil OK`, подпись валидна
- [x] Fallback проверен вживую (`OPENCODE_SERVICE_CONFIG=/nonexistent`): `source=database`,
      totals совпали с API точь-в-точь (**30 748 445**); прямой V2 stats дал те же цифры
- [x] README / PLAN обновлены, макросы SwiftUI не вернулись, аудит чист

### Раунд 3 — выбор метра для иконки трея

- [x] `TrayMeter` + `AppDefaultsKey.trayMeter` + `UsageSnapshot.meter(for:)` в Core;
      `TrayMeter.\`default\` = .rolling`; `worst` / `meters` не изменены
- [x] Picker «В строке меню» в настройках; иконка обновляется мгновенно
      (Combine-sink только на `updateTrayMeter()`, без `refresh()` и без сети)
- [x] три карточки в попапе (`usage.meters`) и уведомления не изменены
- [x] `swift build -c release` — Build complete; `make test` — **116 passed, 0 failed**;
      `make smoke` — **120 passed, 0 failed** (живые лимиты `21 / 8 / 51`)
- [x] `make app` — `plutil OK`, `codesign valid`
- [x] SQL-эталон совпал: **243 сообщения / 18 757 834 токена**
- [x] README обновлён, макросы SwiftUI и XCTest не вернулись, аудит чист

### Дефекты, найденные проверкой (исправляются раундом 2)

| # | Дефект | Решение |
| --- | --- | --- |
| 1 | В системе только CommandLineTools: нет `XCTest.framework` → `swift test` падает | `Package.swift`: `testTarget` → `executableTarget`; тесты переписаны на dependency-free runner; `make test` / `make smoke` |
| 2 | Нет `SwiftUIMacros` plugin → `@State` не компилируется | UI без макросов: `@StateObject` + `ObservableObject` (агент 2 нашёл сам) |
| 3 | `ActivityView` зашит на 30 дней, а история в основном янв–июн 2026 → график из одного столбца | `AppDefaultsKey.activityPeriod`, `ActivitySnapshot.monthly`, picker 7/30/90/Всё время |
| 4 | `UsageMeter.isCritical` = настраиваемый порог (80), а `TrayIcon` краснел на 85 | иконка использует `meter.isCritical` |

### Уточнённый SQL-эталон (БД живая, цифры растут по мере работы агента)

| Метрика | 30 дней | Всё время |
| --- | --- | --- |
| assistant-сообщений | 137 | 643 |
| total tokens | 7 535 923 | 32 721 312 |
| cost, USD | 0.0 | 0.181899 |

Порог 30 дней = `2026-10-24 10:55` (первый замер с порогом «~15 часов» был ошибкой планировщика, исправлено).
Если totals из `ActivityService` окажутся ~в 2 раза выше эталона → случайно прочитана и таблица `part`.

## 5. SQL-эталон для сверки (снимок 2026-11-23, БД живая — цифры растут)

Прямой запрос **только** к `session_message` (без `part`):

| Метрика | Значение |
| --- | --- |
| assistant-сообщений | 532 |
| input | 3 110 813 |
| output | 240 051 |
| reasoning | 87 635 |
| cache read | 22 589 888 |
| cache write | 0 |
| **total tokens** | **26 028 387** |
| cost, USD | 0.181899 |
| за последние 30 дней | 26 сообщений (все — сегодня) |

`ActivityService.load(days: 30)` должен дать те же totals в пределах дельты новых сообщений.
Если сумма окажется ~в 2 раза больше → агент случайно прочитал и `part`, и `session_message`.

**Вывод для UX:** за 30 дней почти пустой график (история в основном январь–июнь 2026),
поэтому в `ActivityView` нужен переключатель периода (7 / 30 / 90 / всё время), а не только 30 дней.

## 6. Активность из API (исследование, 2026-11-23)

**ИТОГ: API есть.** Первый вывод «API нет» был ошибкой планировщика: искался удалённый
Console API, а нужный оказался **локальным V2 API OpenCode Desktop 2.3.0**
(`/Applications/OpenCode.app` → `~/Library/Application Support/ai.opencode.desktop/cli/2.3.0-arm64/opencode-cli serve --service`, порт 49374).

| Эндпоинт | Результат |
| --- | --- |
| `GET /api/experimental/session/stats` | ✅ `{"data":{range,sessions,subagents,prompts,steps,tokens,cost,tools,activeDays,streak,activity:[{date,steps}],models:[{model,steps,tokens,cost}]}}` |
| `GET /api/experimental/session/stats?from=<ms>&to=<ms>&tools=none` | ✅ работает период 7/30/90/всё, ответ в `.data` |
| `GET /api/session` | ✅ `{"data":[{id,title,projectID,model,cost,tokens,time,outcome}]}` |
| `GET /api/experimental/usage/limits?location[directory]=…` | ⚠️ `data: null` — desktop не видит Go-подписку; лимиты остаются на прямом `/inference/go/v1/usage` |
| Авторизация | `Authorization: Basic base64("opencode:" + password)` из `~/.config/opencode/service.json` → 200. Вариант `base64(":password")` / `base64(password)` даёт 401 |
| Discovery порта | `opencode-cli service status` → `http://127.0.0.1:49374` |

**Решение (раунд 4):** `ActivityService` становится API-primary с fallback на SQLite;
`ActivitySnapshot.source` показывает источник в UI. Прямой парсинг БД остаётся
страховкой, когда Desktop-сервис не запущен.

Ниже — сохранённая таблица проверок **публичного Console API** (там истории действительно нет):

**Публичный Console API истории не отдаёт.** Проверено live-запросами с рабочим ключом `oc_sk_…`:

| Источник | Результат |
| --- | --- |
| `GET /inference/go/v1/usage` | 200, но только 3 текущих метра (`percent`/`status`/`resetsAt`), без истории |
| `opencode.allowance` в ответе inference | $ за конкретный запрос, только в момент ответа, ретроспективно недоступно |
| `GET /console/api/v1/models` | 200 — каталог моделей, не история |
| `/console/api/v1/{usage*,activity*,logs,stats,billing,budgets,members,me}`, `/inference/go/v1/usage/history`, `/inference/v1/usage` | **404** с API-ключом (~30 путей) |
| Console UI «Activity → Usage» + CSV-экспорт 7/30/90 дней | существует в браузере, но это внутренние endpoint'ы cookie-сессии; JS-бандлы публичного лендинга их не содержат |
| Permission `Usage: Read` в docs/console/api | упоминается, но рабочий REST-путь под API-ключ не документирован |

**Вывод:** локальная БД остаётся единственным источником детальной активности
(токены по типам, модели, проекты, сессии) — API в принципе не содержит этих полей.
Её ограничение: только эта машина.

**Возможное развитие (не реализовано, ждёт решения пользователя):**
1. *Накопитель снимков* — писать три процента + время при каждом опросе в локальный
   стор приложения и строить график дельты расхода allowance. Покрывает все клиенты
   подписки, не требует недокументированных endpoint'ов. История — с момента установки,
   в процентах лимита, а не в токенах.
2. *Импорт CSV* из Console (Activity → Usage → Export usage) — точные деньги по дням/
   моделям/людям со всех клиентов, но вручную.

Оба варианта дополняют локальную БД, а не заменяют её.

### Раунд 6 — энергосбережение + меню правого клика

- [x] `PowerState` (ac / battery / lowPower / unknown), `PowerState.parse`, `PowerMonitor`
      (`ProcessInfo.isLowPowerModeEnabled` + `/usr/bin/pmset -g batt`, кеш 60 с, таймаут 3 с).
      На этой машине: `'AC Power'`, LPM выключен → `.ac`
- [x] `AppConfig.effectivePollInterval(base:battery:state:enabled:)` + интервалы:
      опрос 60→300 с, тик иконки 30→60 с, активность 5→15 мин
- [x] Настройки: «Уменьшать опрос от батареи» (по умолчанию вкл.),
      «Интервал от батареи» (1/5/15 мин), живая подпись питания и интервала
- [x] Адаптивные таймеры + `NSWorkspace.willSleepNotification` / `didWakeNotification`
      (пауза таймеров во сне, `refresh(requestActivity: true)` при пробуждении)
- [x] `NSStatusItem` вместо `MenuBarExtra`: левый = `NSPopover` с `MenuBarView`,
      правый = `NSMenu` («Открыть», «Настройки…», «Выход»); `statusItem.menu`
      никогда не выставляется, поэтому левый клик не показывает меню
- [x] Один `AppState()` в `AppDelegate`, переиспользуется в Settings scene и StatusBarController
- [x] **Приёмка вживую:** `.app` запущен на 5 с — процесс жив, краш-репортов нет,
      `pmset -g assertions` не содержит наш процесс (сон не удерживается), процесс завершён
- [x] **Дефект приёмки исправлен:** при основном интервале 30 с подпись показывала
      «раз в 0 мин» — теперь «30 сек»
- [x] `swift build -c release`, `make test` — **179 passed, 0 failed**,
      `make smoke` — **183 passed, 0 failed**, `make app` — подпись валидна
- [x] Никаких power assertions, макросов SwiftUI, логов секретов; аудит чист

### Раунд 7 — верстка окна настроек

**Проблема (скриншот пользователя):** окно 380×460 без `.resizable`, `Form` не скроллится,
нижняя секция «Запуск при входе в систему» обрезана, русские подписи и пояснения
сжимаются в «…».

- [x] Окно 480×640, `.resizable`, `minSize` 440×420, `maxSize` 760×1100,
      `isReleasedWhenClosed = false`; `CGWindowList` подтвердил **470×654** вместо 380×460
- [x] `ScrollView { Form { … } }`, перенос всех 8 caption через
      `.fixedSize(horizontal: false, vertical: true)`, без `.lineLimit(1)`
- [x] Отладочный env `OPENCODE_SHOW_SETTINGS_ON_LAUNCH=1` открывает окно без клика
      (без переменной — обычный запуск)
- [x] `swift build -c release`, `make test` — **179 passed, 0 failed**,
      `make smoke` — **183 passed, 0 failed**, `make app` — подпись валидна
- [x] **Дефект приёмки исправлен:** `make run` (bare binary без `.app`) падал в
      `UNUserNotificationCenter.current()` с `bundleProxyForCurrentProcess is nil` —
      добавлен `guard Bundle.main.bundleIdentifier != nil` в `Notifier.requestAuthorization()`,
      уведомления в этом режиме деградируют до `NSSound.beep()`. Проверено вживую.
- [x] Визуальный скриншот не удался: окно оказалось на дополнительном дисплее
      (отрицательные координаты), `screencapture -l/-R` требует Screen Recording.
      Вместо этого подтверждены размеры окна через `CGWindowList` и проверен код верстки.
- [x] README / PLAN обновлены, макросы SwiftUI не вернулись
- [x] Тестовый процесс завершён по PID; запущенный у пользователя
      `/Applications/OpenCodeLimits.app` (PID 41773) НЕ тронут — ему нужен перезапуск,
      чтобы подхватить новый бинарник

## 7. Сон и энергопотребление (проверено 2026-11-23)

**Приложение НЕ препятствует засыпанию Mac.** В коде отсутствуют:
`IOPMAssertionCreate*`, `NSProcessInfo.beginActivity`, `idleSystemSleepDisabled`,
`disableSuddenTermination`, `NSBackgroundActivityScheduler`, `caffeinate`,
background `URLSession`, а также какие-либо `Info.plist`-ключи, влияющие на сон.

`pmset -g assertions` на живой машине: сон удерживают `Google Chrome` (Playing audio),
`coreaudiod`, `bluetoothd`, `powerd`, `mds` — процесса приложения в списке нет.
macOS засыпает по отсутствию пользовательского ввода; таймеры и сеть приложения
не считаются пользовательской активностью. Во сне `Timer` приостанавливается
(coalescing) и при пробуждении даёт одно догоняющее срабатывание.

Пока ноутбук бодрствует: 1 сетевой запрос / 60 с, перерисовка иконки / 30 с,
чтение локального V2 API / 5 мин. Системные `powernap 1` и `tcpkeepalive 1`
могут будить Mac сами по себе — приложение wake не запрашивает.

**Возможное улучшение (не реализовано):** `NSWorkspace.willSleepNotification` /
`didWakeNotification` для остановки таймеров во сне и мгновенного обновления при
пробуждении, плюс увеличение интервала опроса в Low Power Mode.

### Раунд 8 — `.gitignore`, аудит секретов, финальный README

- [x] `.gitignore`: `.build/`, `build/`, `.swiftpm/`, `DerivedData/`, `*.app/`,
      `*.log`, `.env*`, `.DS_Store`, временные файлы редакторов.
      `git check-ignore` подтвердил: `.build/` (**1.1 ГБ**) и `build/` (1.4 МБ) скрыты
- [x] **Репозиторий чист:** `git ls-files` = 0, коммитов нет, remote нет,
      `git count-objects` = 4 КиБ → в историю никогда ничего не попадало
- [x] **Сканирование на секреты:** реальных `oc_sk_…` (длина 51) нет — только
      шаблоны/тестовые значения длиной 14 в README / PLAN / тестах; base64 от
      `opencode:` нет; `service.json`, `auth.json`, `*.db`, `.env*` внутри проекта нет;
      «длинные строки» оказались именами методов (`applicationShouldTerminate…`)
- [x] README полностью переписан на русском: убрано устаревшее утверждение
      «активность из локальной БД», добавлены правый клик, два кольца, энергосбережение/сон,
      таблица источников данных, раздел «Безопасность и приватность», диагностика
      и актуальная структура проекта
- [x] `make test` — **179 passed, 0 failed**

### Раунд 9 — документация в `docs/`

- [x] `docs/README.md` (59) — навигация по 8 документам + история раундов 1–8
- [x] `docs/architecture.md` (148) — 4 таргета, слои, Mermaid-диаграммы, решения, lifecycle
- [x] `docs/data-sources.md` (221) — Go usage API, локальный V2 API, SQLite fallback,
      схемы полей, авторизация, семантика трёх окон, запрет таблицы `part`
- [x] `docs/configuration.md` (116) — 10 ключей UserDefaults, 5 env, Keychain, прокси,
      автозапуск, `Info.plist`
- [x] `docs/ui.md` (84) — два кольца, левый/правый клик, попап, активность, настройки,
      уведомления, энергосбережение
- [x] `docs/build-and-test.md` (75) — make-цели, раннер без XCTest, `.app`, отладка, CLT
- [x] `docs/security.md` (109) — границы доверия, секреты вне репозитория, `.gitignore`, аудит
- [x] `docs/troubleshooting.md` (42) — таблица симптомов + безопасная диагностика
- [x] Итого **8 файлов / 854 строки**; корневой `README.md` ссылается на `docs/`
- [x] Приёмка: **74 локальные ссылки, битых 0**; все 10 UserDefaults-ключей и 5 env
      совпадают с кодом; реальных секретов и CJK-артефактов нет; `git status` показывает `docs/`

### Раунд 10 — сборка через GitHub Actions

- [x] `.github/workflows/build.yml` (91 строка): `macos-latest`, `make test` → `make app` →
      `plutil -lint` / `codesign -v` → `ditto` ZIP → `upload-artifact@v4` (14 дней)
- [x] Триггеры: `push main`, `pull_request`, `tags v*`, `workflow_dispatch`;
      `concurrency` отменяет устаревшие прогоны; `permissions: contents: read`
- [x] Job `release` по тегу `v*` → `download-artifact` (`path: build`,
      `merge-multiple: true`) → `gh release create --generate-notes` с `GITHUB_TOKEN`
- [x] `make smoke` в CI ЗАПРЕЩЁН (только в комментарии); `swift test` / `make install` /
      `make run` не вызываются; секретов и ключей в YAML нет
- [x] Нотаризация не реализована — только ad-hoc подпись; комментарий перечисляет
      нужные Apple-секреты для будущего распространения
- [x] `docs/build-and-test.md` (секция «CI / GitHub Actions») + корневой `README.md` обновлены
- [x] **Локальный прогон цикла CI:** `swift build -c release` → Build complete;
      `make test` — 179 passed; `make app` — `plutil OK`, `codesign valid`;
      `build/OpenCodeLimits.zip` = **361 КБ**, `.app` = 1.4 МБ, Mach-O arm64,
      ключей в бинарнике нет
- [x] YAML валиден (`ruby YAML.load_file` → OK); `git status` показывает `.github/`
- [ ] Первый пуш ещё не сделан → workflow заработает после `git push -u origin main`

### Раунд 11 — hotfix первого прогона CI

**Ошибка:** `Sources/OpenCodeLimits/main.swift:40: error: 'main' attribute cannot be used in a module that contains top-level code`.
Локально не проявлялась из-за инкрементального кэша `.build/`; на чистом checkout
GitHub Actions (`macos-latest`) компилятор закономерно отказал.

- [x] `main.swift` → **`OpenCodeLimitsApp.swift`** (имя файла — причина, содержимое не менялось)
- [x] Обновлены `docs/architecture.md`, корневой `README.md`, `PLAN.md`
- [x] **Чистая сборка** (`swift package clean` → `swift build -c release`) — Build complete,
      `make test` — 179 passed, `make app` — `plutil OK` / `codesign valid`
- [x] В workflow добавлена проверка? Нет — на CI всегда чистый checkout, переименования достаточно
- [ ] Повторный прогон Actions после пуша фикса

### Привязка репозитория

- [x] `origin = https://github.com/saneksa/opencode-limits.git`; `git ls-remote` → exit 0,
      удалённый репозиторий доступен и пуст; ветка `main`, коммитов 0,
      `credential.helper = osxkeychain`
- [x] `git add -An .` → 39 файлов, `.build/` и `build/` исключены
- [ ] Первый коммит и `git push -u origin main` — ждёт команды пользователя

## 8. Риски

| Риск | Митигация |
| --- | --- |
| modulemap не найдёт `sqlite3.h` | shim с `<sqlite3.h>` + sysroot; fallback — `/usr/bin/sqlite3 -json` |
| Схема БД opencode изменится | все чтения через `json_extract` с `COALESCE`, пустой результат вместо краша |
| Ключ обновился / подписка кончилась | ключ читается заново каждый опрос; 401/403 показываются баннером в UI |
| Прокси отключился | `ProxyProvider` fallback на env и обычную конфигурацию, таймаут 15 с |
| Уведомления не работают без `.app` | `UNUserNotificationCenter` + fallback `NSSound.beep()`, `SMAppService` ошибки ловятся |
| Go API экспериментальный | ошибки не роняют приложение, сохраняется последний удачный снимок |
