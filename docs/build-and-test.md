# Сборка и тестирование

См. также: [README](../README.md), [Журнал разработки](development-log.md), [Архитектура](architecture.md), [Источники данных](data-sources.md), [Настройки](configuration.md), [Пользовательский интерфейс](ui.md), [Безопасность](security.md), [Устранение неполадок](troubleshooting.md).

## Требования

- **macOS 13+**.
- **SwiftPM** с Xcode Command Line Tools (на этой машине — Swift 6.4.2). Полная установка Xcode не нужна.
- **Никаких внешних пакетов**: только системные фреймворки (SwiftUI, AppKit, Charts, UserNotifications, ServiceManagement, Foundation, Combine, SystemConfiguration, Security, SQLite3).
- `Package.swift` использует `swift-tools-version: 5.9` и режим языка Swift 5.

## Команды Makefile

| Цель | Команда | Назначение |
| --- | --- | --- |
| `make build` | `swift build -c release` | Сборка release-бинарника |
| `make test` | `swift run -c release OpenCodeLimitsTests` | Локальный прогон тестов без сети и БД |
| `make smoke` | `OPENCODE_LIVE_SMOKE=1 swift run -c release OpenCodeLimitsTests` | Тесты + живые проверки API и БД |
| `make run` | `swift run OpenCodeLimits` | Запуск из исходников (без бандла) |
| `make app` | сборка `Contents/{MacOS/OpenCodeLimits,Info.plist,PkgInfo,Resources/AppIcon.icns}` + `codesign --force --sign -` | Сборка настоящего `.app` с иконкой и ad-hoc подписью |
| `make icon` | `swift scripts/generate-appicon.swift` | Пересборка `Resources/AppIcon.png` и `AppIcon.icns` (10 размеров через `sips` + `iconutil`) |
| `make install` | `rm -rf /Applications/OpenCodeLimits.app && cp -R …` | Установка в `/Applications` |
| `make clean` | `swift package clean` | Очистка артефактов SwiftPM |

## Тестовый раннер

`OpenCodeLimitsTests` — самостоятельный исполняемый таргет **без XCTest**: `@main struct TestRunner` с помощниками `check` / `equal` / `near` / `fail`. Результат выводится как строки `[PASS]` / `[FAIL]` и итог `N passed, M failed`; при наличии ошибок процесс завершается ненулевым кодом.

Текущие результаты:

- `make test` — **179 passed / 0 failed**
- `make smoke` — **183 passed / 0 failed**

Живой smoke-режим печатает проценты Go-лимитов и итоги активности с `source=api`. Ключ и заголовки запросов никогда не выводятся.

## Info.plist

- Bundle identifier: `dev.alex.opencodelimits`
- `LSUIElement = true` — приложение без значка в Dock
- Минимальная версия: macOS 13.0
- Версия: 0.1.0

## Переменные окружения

| Переменная | Действие |
| --- | --- |
| `OPENCODE_SHOW_SETTINGS_ON_LAUNCH=1` | Открыть окно настроек сразу при запуске (для отладки вёрстки). Без переменной приложение стартует **без единого окна** — только иконка в строке меню |
| `OPENCODE_LIVE_SMOKE=1` | Включить живые сетевые проверки и проверки БД в тестах |
| `OPENCODE_DB_PATH` | Переопределить путь к `opencode.db` |
| `OPENCODE_SERVICE_CONFIG` | Переопределить путь к конфигурации сервиса |
| `OPENCODE_GO_KEY` | Переопределить ключ API (используйте подставное значение `<ключ>` в примерах) |

«Запуск при входе в систему» реализован через `SMAppService.mainApp.register()/unregister()` и работает только из настоящего `.app`, установленного в `/Applications`.

## Особенности окружения с CommandLineTools

- `XCTest.framework` отсутствует — поэтому тесты запускаются через `make test`, а не через `swift test`.
- Плагин макросов `SwiftUIMacros` отсутствует — в UI не используются `@State`, `@AppStorage`, `#Preview`, `@Observable`, `@Environment(\.openSettings)`.
- `sqlite3.h` доступен только в sysroot SDK; для этого есть таргет-заглушка `CSQLite3`.
- Предупреждения компоновщика об отсутствующих путях `Developer/Library/Frameworks` безвредны.
- Системный HTTPS-прокси задаётся через `scutil --proxy` (127.0.0.1:1082), а не переменными окружения. `curl` требует флага `-x`, а `URLSession` читает настройки через `SystemConfiguration`.

## Команды проверки, используемые сопровождающим

```sh
swift build -c release
make test
make smoke
make app
plutil -lint build/OpenCodeLimits.app/Contents/Info.plist
codesign -v build/OpenCodeLimits.app
git status --short
git check-ignore -v .build build
```

Дополнительно по теме: [Устранение неполадок](troubleshooting.md).

## CI / GitHub Actions

Непрерывная интеграция описана в `.github/workflows/build.yml`. Запуск происходит по `push` в ветку `main`, по `push` тегов вида `v*`, по `pull_request` в `main` и вручную через `workflow_dispatch`. Для одного ref одновременно выполняется только один запуск: предыдущий отменяется через `concurrency` с `cancel-in-progress: true`.

Задача `build` выполняется на `macos-latest` (runner с macOS обязателен: SwiftUI/AppKit, macOS SDK и `codesign` недоступны на Linux) с лимитом 30 минут. Шаги:
- `actions/checkout@v4`;
- вывод инструментов — `swift --version` и `xcrun --show-sdk-path`;
- `make test` — раннер без внешних зависимостей, не использующий XCTest (команда `swift test` в CI **не** применяется: в некоторых установках CommandLineTools нет `XCTest.framework`);
- `make app` — сборка `.app` с ad-hoc подписью;
- проверка бандла — `plutil -lint build/OpenCodeLimits.app/Contents/Info.plist` и `codesign -v --verbose=2 build/OpenCodeLimits.app`;
- упаковка через `ditto -c -k --sequesterRsrc --keepParent` в `build/OpenCodeLimits.zip`;
- загрузка ZIP как артефакта `OpenCodeLimits-macos-${{ github.sha }}` с `if-no-files-found: error` и хранением 14 дней.

**`make smoke` в CI никогда не запускается**: он требует настоящего ключа OpenCode Go и запущенного локального сервиса OpenCode Desktop V2, а также обращается к opencode.ai. Для проверки в изолированном окружении достаточно `make test`.

Артефакт доступен в разделе Actions → нужный запуск → **Artifacts**: `OpenCodeLimits-macos-<sha>.zip`. Срок хранения — 14 дней.

Задача `release` срабатывает только для тегов `refs/tags/v*` после успешной сборки. Она скачивает тот же артефакт в каталог `build` и создаёт GitHub Release через `gh release create "$GITHUB_REF_NAME" build/OpenCodeLimits.zip --generate-notes --title "$GITHUB_REF_NAME"` с токеном `GITHUB_TOKEN` (разрешение `contents: write`). Чтобы выпустить версию:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Текущий `.app` подписан **ad-hoc** (`codesign --force --sign -`): этого достаточно для локального запуска, но Gatekeeper заблокирует приложение у других пользователей. Для нотаризации потребуются сертификат `Developer ID Application` и секреты `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. Они намеренно не используются в workflow — подробнее о работе с секретами в [Безопасности](security.md).
