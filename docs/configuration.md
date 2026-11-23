# Конфигурация

Навигация: [документация](README.md) · [архитектура](architecture.md) ·
[источники данных](data-sources.md) · [безопасность](security.md)

Настройки хранятся в `UserDefaults` (ключи определены в `AppDefaultsKey`) и
применяются `Settings` / `AppState` сразу при изменении. Секреты в `UserDefaults`
**не попадают** — там только идентификатор выбранного источника ключа.

## UserDefaults

| Ключ | Тип | Значение по умолчанию | Допустимые значения | Эффект |
| --- | --- | --- | --- | --- |
| `powerSaving` | Bool | `true` | `true` / `false` | Включает замедление опроса на батарейке / в Low Power Mode |
| `batteryPollInterval` | Double | `300` (с) | `60`, `300`, `900` | Интервал опроса при энергосбережении |
| `trayMeter` | String | `"rolling"` | `rolling`, `weekly`, `monthly`, `auto` | Какое окно показывает цифру процента в иконке; `auto` = `worst` |
| `activityPeriod` | Int | `30` | `7`, `30`, `90`, `0` («Всё время») | Период графика активности |
| `pollInterval` | Double | `60` (с) | `30`, `60`, `300` | Базовый интервал опроса лимитов |
| `warnThreshold` | Int | `80` | 0...100 (обрезается) | Порог подсветки и уведомления |
| `keySource` | String | `"opencode.db"` | `opencode.db`, `Keychain`, `OPENCODE_GO_KEY` | Приоритетный источник ключа Go API |
| `launchAtLogin` | Bool | `false` | `true` / `false` | Автозапуск через `SMAppService` |
| `activityMetric` | String | `"tokens"` | `tokens`, `cost` | Метрика графика активности |

Всего 9 ключей. Недопустимые значения при чтении заменяются на значения по
умолчанию.

**Иконка в трее.** Единственное кольцо всегда показывает отсчёт до сброса
5-часового лимита (`rolling`) зелёным цветом; ключ `trayMeter` выбирает, какой
лимит выведен цифрой процента внутри кольца. Переключателя внутреннего кольца
больше нет — отдельного ключа для него не существует.

## Переменные окружения

| Переменная | Назначение |
| --- | --- |
| `OPENCODE_DB_PATH` | Переопределяет путь к `opencode.db` (по умолчанию `~/.local/share/opencode/opencode.db`) |
| `OPENCODE_GO_KEY` | Ключ Go API как источник `environment`; читается только из окружения процесса |
| `OPENCODE_LIVE_SMOKE` | `=1` включает живой запрос в раннере проверок (`make smoke`) |
| `OPENCODE_SERVICE_CONFIG` | Переопределяет путь к `~/.config/opencode/service.json` (пароль локального V2 API) |
| `OPENCODE_SHOW_SETTINGS_ON_LAUNCH` | `=1` открывает окно настроек сразу после запуска (отладка) |

`HTTPS_PROXY` используется `ProxyProvider` как запасной источник настроек
прокси (см. ниже); в списке кнопок приложения его нет.

## Источники ключа Go API

`CredentialStore` пробует источники в порядке: выбранный пользователем, затем
остальные (`KeySource.allCases`).

| Источник | Где лежит ключ |
| --- | --- |
| `.database` (`opencode.db`) | Таблица `credential`, строка `integration_id = 'opencode-go' AND active = 1`, значение `json_extract(value, '$.key')` |
| `.environment` (`OPENCODE_GO_KEY`) | Переменная окружения процесса |
| `.keychain` (`Keychain`) | Security framework, `kSecClassGenericPassword`, service `dev.alex.opencodelimits`, account `go-api-key` |

Ключ имеет вид `oc_sk_…` и **никогда** не пишется в логи, файлы или
`UserDefaults`. Ручной ключ сохраняется только в Keychain; там же он и
обновляется/удаляется (`SecItemAdd` / `SecItemUpdate` / `SecItemDelete`).
`activeSourceDescription` возвращает только название источника.

## Прокси

`ProxyProvider` читает системные настройки через
`SCDynamicStoreCopyProxies` (`kSCPropNetProxiesHTTPSEnable`, `HTTPSProxy`,
`HTTPSPort`) и переносит их в `URLSessionConfiguration.connectionProxyDictionary`
(`kCFNetworkProxiesHTTPSEnable` = 1, `HTTPSProxy`, `HTTPSPort`). На этой машине
прокси задан через `scutil --proxy` (`127.0.0.1:1082`) и **отсутствует** в
переменных окружения — поэтому одного чтения `HTTPS_PROXY` недостаточно.
Таймаут запроса — 15 с.

Локальный V2 API настраивает свой `URLSession` иначе:
`connectionProxyDictionary = [:]`, таймаут 5 с. Запросы к `127.0.0.1` не должны
проходить через системный прокси.

## Запуск при входе в систему

`Settings` вызывает `SMAppService.mainApp.register()` / `unregister()`. Это
требует настоящего `.app`-бандла (`make install` копирует его в `/Applications`);
при запуске через `swift run` операция может завершиться ошибкой — она
показывается в окне настроек как текст, без падения приложения. Бандл объявлен
как `LSUIElement`, поэтому приложение не появляется в Dock.

## Уведомления

`Notifier` отправляет локальное уведомление macOS один раз на окно при
переходе процента через `warnThreshold` (по умолчанию 80 %) или при статусе
`rate-limited`. Порог настраивается в окне настроек; подсветка карточек и
иконки использует то же значение (`UsageMeter.isCritical`).

## Энергосбережение

`PowerMonitor` определяет состояние через
`ProcessInfo.processInfo.isLowPowerModeEnabled` и `/usr/bin/pmset -g batt`
(таймаут процесса 3 с, кэш результата 60 с). Low Power Mode имеет приоритет
над AC. Интервалы рассчитываются формулой
`enabled && state.isEnergySaving ? max(base, battery) : base`.

| Что | Обычный режим | Батарейка / Low Power Mode |
| --- | --- | --- |
| Опрос лимитов | `defaultPollInterval` = 60 с | `max(60, 300)` = 300 с |
| Перерисовка иконки | `normalClockInterval` = 30 с | `energySavingClockInterval` = 60 с |
| Загрузка активности | `normalActivityInterval` = 300 с | `energySavingActivityInterval` = 900 с |

Таймеры пересоздаются при изменении состояния питания и настроек, ставятся на
паузу во сне и перезапускаются при пробуждении.

## Info.plist

| Ключ | Значение |
| --- | --- |
| `CFBundleIdentifier` | `dev.alex.opencodelimits` |
| `CFBundleName` | `OpenCode Limits` |
| `CFBundleExecutable` | `OpenCodeLimits` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` |
| `LSMinimumSystemVersion` | `13.0` |
| `LSUIElement` | `true` (без иконки в Dock) |
| `NSHighResolutionCapable` | `true` |

См. также: [Источники данных](data-sources.md),
[Сборка и тесты](build-and-test.md), [Безопасность](security.md).
