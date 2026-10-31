# ZCode Fold

Мобильный клиент для ZCode (z.ai) под Android — с прицелом на раскладные телефоны
(Honor Magic V3 и подобные). В разложенном состоянии работает в две колонки:
слева проекты и сессии, справа живой чат с агентом.

**Скачать:** [Releases](https://github.com/rukazax/zcode-fold/releases) · APK ~18 МБ (arm64, debug-подпись для sideload).

Связка не реверсит приватный протокол ZCode, а использует официальный runtime через
**ACP** (`zcode app-server --stdio`) и hub с токеном — поэтому клиент переживает
обновления ZCode и видит те же сессии, что и редактор на ПК.

```
телефон ──WSS── Cloudflare Tunnel ── hub :8377 ── bridge ── zcode app-server
                                        ▲
                          Zed / VS Code ─┘ (та же сессия)
```

## Что умеет

- 📱 Адаптив под раскладку: одна колонка на внешнем экране, две — на внутреннем;
  учитывается шарнир (`MediaQuery.displayFeatures`), полоса под него не используется.
- 💬 Стриминг ответов, «размышления» отдельным сворачиваемым блоком, карточки
  вызовов инструментов с раскрытием вывода, планы задач.
- 🔐 Подтверждения (`session/request_permission`) приходят прямо на телефон —
  можно разрешить или отклонить запуск команды.
- 🌐 Работает из мобильного интернета: hub поднимается на ПК и публикуется
  Cloudflare quick tunnel'ом (или любым своим туннелем).
- 🔁 Автопереподключение с восстановлением истории после сна/смены сети.
- 🎛 Переключение модели и режима (plan/build/edit/yolo) из шапки, индикатор
  заполнения контекста.
- 🗂 Несколько hub-подключений, токены лежат в Android Keystore
  (`flutter_secure_storage`), черновики сообщений переживают перезапуск.
- 🧾 Рендер markdown-lite: блоки кода с копированием, inline-код, жирный.

## Быстрый старт

### 1. ПК (Windows)

Нужны Node.js ≥ 22 и установленный ZCode (CLI лежит внутри десктопного приложения).

```powershell
cd zCode_mobile\backend
npm install zcode-acp-server --ignore-scripts   # один раз
.\start.cmd -Tunnel
```

Скрипт:
1. сгенерирует токен (`.token`) и поднимет hub на `127.0.0.1:8377`;
2. запустит headless-мост для текущего проекта;
3. скачает `cloudflared` и поднимет публичный туннель;
4. напечатает адрес (локальный, LAN и `https://…trycloudflare.com`) и токен.

Пример вывода:

```
  Локально : http://127.0.0.1:8377
  В сети   : http://192.168.1.42:8377
  Интернет : https://quiet-river-1234.trycloudflare.com
  Токен    : 8f3c…
```

Без туннеля: `.\start.cmd` (только LAN). Остановить всё: `backend\stop.ps1`.

### 2. Телефон

Собрать APK:

```powershell
cd app
flutter build apk --release
# app\build\app\outputs\flutter-apk\app-release.apk
```

Поставить на телефон (или `adb install`), открыть, ввести адрес hub и токен.

> ⚠️ Токен = полный доступ ко всем агентским сессиям машины. Не публикуй его
> и не оставляй quick tunnel включённым без необходимости.

## Разработка

```powershell
flutter run              # отладка на подключённом устройстве
flutter analyze
flutter build apk --debug
```

Структура:

```
app/lib/
  main.dart                  вход, тема, secure storage
  src/acp_client.dart        JSON-RPC/ACP поверх WebSocket, initialize, replay
  src/hub_api.dart           REST hub: /api/health, /api/instances
  src/app_state.dart         состояние: подключения, сессия, сообщения, реконнект
  src/models.dart            типы hub/ACP, парсинг апдейтов
  src/ui/fold_layout.dart    геометрия раскладки (шарнир, пороги)
  src/ui/home_page.dart      адаптивный shell: 1 или 2 колонки
  src/ui/sessions_pane.dart  проекты, сессии, «новый чат»
  src/ui/chat_pane.dart      чат, tool-карточки, пермишены, композер
backend/
  start.ps1 / start.cmd      hub + serve + туннель
  stop.ps1                   остановить процессы
  hub.cmd / serve.cmd        обёртки запуска
```

## Как это работает

1. `initialize` (protocolVersion = 1, без elicitation-форм).
2. `session/load {sessionId, cwd, mcpServers}` — hub отдаёт историю как
   `session/update`, дальше стрим идёт в реальном времени.
3. `session/prompt {prompt:[{type:"text"}]}` — ход агента; `session/cancel` —
   остановка.
4. `session/request_permission` — серверный запрос, ответ
   `{outcome:{outcome:"selected",optionId}}`.
5. Расширения моста `$/zcode/turnState` дают статус «работает/свободен» и расход
   токенов; `config_option_update` — модель/режим.

## Ограничения

- Hub на Windows, туннель — Cloudflare quick (адрес меняется при перезапуске).
  Постоянный домен: свой named tunnel или Tailscale.
- Первый кадр после долгого сна может прийти с задержкой — клиент сам
  переподключается и переигрывает историю.
- Прикрепление файлов и картинок пока не сделано (текст + слэш-команды).
- iOS не собирался, но код платформенно-нейтральный.
