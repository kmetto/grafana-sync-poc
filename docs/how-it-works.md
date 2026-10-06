# Как это всё работает (объяснение на пальцах)

> Статус на 2026-10-06: части, помеченные **[будет]**, ещё в работе (план `docs/superpowers/plans/2026-10-06-multi-client-git-sync.md`, задачи 4–7). Остальное уже работает.

---

## 1. Что мы вообще делаем

У нас есть **клиенты**. Каждому клиенту мы делаем дашборды в Grafana.

- Мы рисуем дашборды в **одной своей Grafana** — это **dev**. В ней у каждого клиента своя папка.
- У каждого клиента есть **своя Grafana** — это его **prod**. Там дашборды только смотрят, менять нельзя.
- Между ними — **GitHub**. У каждого клиента свой репозиторий, дашборды лежат там как JSON-файлы.

Дашборд попадает к клиенту так:

```
Я сохранил дашборд           Он оказался              Я сделал PR и            Grafana клиента
в папке клиента в dev   →    в репо клиента,     →    смержил его       →      сама подтянула
                             ветка dev                в ветку main             изменения из main
```

Руками в prod клиента никто ничего не делает. Всё приходит из git.

---

## 2. Кто есть кто

| Что | Где | Зачем |
|---|---|---|
| **dev Grafana** | http://localhost:3000 | Наша рабочая Grafana. Папка на каждого клиента. |
| **prod Grafana клиента N** | http://localhost:3001, 3002, 3003 | Grafana клиента. Только чтение. В POC это наши контейнеры, в жизни — у клиента. |
| **репо клиента N** | github.com/kmetto/grafana-client-N | Здесь лежат дашборды клиента (папка `grafana/`). Ветка `dev` — черновики, ветка `main` — то, что видит клиент. |
| **этот репо** (`grafana-sync-poc`) | github.com/kmetto/grafana-sync-poc | Только код: Terraform, docker-compose, скрипты, документация. Дашбордов тут нет. |

Логин во всех Grafana: `admin` / `admin`.

---

## 3. Git Sync — что это и как работает

**Git Sync** — встроенная функция Grafana, которая связывает **папку в Grafana** с **папкой в git-репозитории**.

### Repository (главное понятие)

Чтобы связать Grafana с git, в Grafana создаётся объект **Repository**. Это просто **настройка**, она живёт **внутри Grafana**, а не в git. В ней написано:

- какой репозиторий (`https://github.com/kmetto/grafana-client-2`)
- какая ветка (`dev` или `main`)
- какая папка в репо (`grafana/`)
- каким токеном ходить в GitHub
- как часто проверять изменения (каждые 30 секунд)
- можно ли писать обратно в git (`workflows`)

Когда Repository создан, Grafana **сама** создаёт под него папку (название папки = `title` из настроек).

### Что делает Grafana после этого

1. **Каждые 30 секунд** смотрит в GitHub: есть ли новый коммит в ветке?
2. Если есть — читает JSON-файлы из `grafana/` и приводит папку к тому же виду: новые дашборды создаёт, изменённые обновляет, удалённые удаляет.
3. Если в настройке `workflows: ["write"]` — когда ты жмёшь **Save** на дашборде, Grafana делает **коммит** в репо. Одно сохранение = один коммит.
4. Если `workflows: []` — сохранять нельзя совсем. Это **read-only**. Так настроены все prod.

### Connection (пока не используем)

**Connection** — отдельный объект, в котором хранится только «как попасть в GitHub» (например, ключи GitHub App). Несколько Repository могут ссылаться на одну Connection, чтобы не хранить токен в каждом. Сейчас у нас токен (PAT) лежит прямо в каждом Repository, поэтому Connection не нужна. Для реальных клиентов лучше перейти на GitHub App + Connection.

### Что важно знать про Git Sync

- **В git попадают только дашборды внутри синхронизируемой папки.** Дашборд вне папки клиента в git не попадёт.
- **Git Sync не умеет «подключиться» к уже существующей папке.** Он всегда создаёт свою.
- **uid дашборда должен быть уникальным во всей Grafana.** Если у двух клиентов в репо лежит дашборд с одинаковым uid — в нашей общей dev Grafana будет конфликт. Новые дашборды из UI получают случайный uid, так что проблема только при копировании.
- Вебхуков нет (GitHub не достучится до localhost), поэтому задержка до 30 секунд.

---

## 4. Схема целиком

```
                 dev Grafana :3000 (наша)
  ┌──────────────────────────────────────────────────┐
  │ папка "Client 1"  ← Repository client-1-dev      │──┐
  │ папка "Client 2"  ← Repository client-2-dev      │──┼─┐
  │ папка "Client 3"  ← Repository client-3-dev      │──┼─┼─┐
  └──────────────────────────────────────────────────┘  │ │ │   (Save = коммит в ветку dev)
                                                        ▼ ▼ ▼
  GitHub:   grafana-client-1      grafana-client-2      grafana-client-3
            dev ──PR──▶ main      dev ──PR──▶ main      dev ──PR──▶ main
                         │                     │                     │   (каждые 30 сек)
                         ▼                     ▼                     ▼
            Grafana :3001          Grafana :3002          Grafana :3003
            Repository             Repository             Repository
            client-1-prod (RO)     client-2-prod (RO)     client-3-prod (RO)
```

Клиенты не видят друг друга: у каждого свой репо и своя Grafana.

---

## 5. Файлы в этом репо

```
graphana-sync/
├── clients.json                 ← СПИСОК КЛИЕНТОВ. Всё начинается отсюда.
├── docker-compose.yml           ← какие Grafana запускать локально
├── .env                         ← секреты (токен GitHub, пароль). НЕ в git.
├── .env.example                 ← шаблон для .env
├── scripts/
│   ├── lib.sh                   ← общие функции для скриптов
│   ├── bootstrap-repos.sh       ← создаёт репо клиентов на GitHub
│   ├── tf.sh                    ← [будет] запускает Terraform
│   ├── verify.sh                ← [будет] проверяет, что всё синхронизировалось
│   └── e2e.sh                   ← [будет] автотест всего процесса
└── terraform/
    ├── modules/git-sync-repo/   ← «как создать один Repository»
    ├── dev/                     ← [будет] настройка dev Grafana
    └── client-prod/             ← [будет] настройка prod одного клиента
```

---

## 6. `clients.json` — список клиентов

```json
{
  "client-1": { "title": "Client 1", "repo": "kmetto/grafana-client-1", "prod_url": "http://localhost:3001" },
  "client-2": { "title": "Client 2", "repo": "kmetto/grafana-client-2", "prod_url": "http://localhost:3002" },
  "client-3": { "title": "Client 3", "repo": "kmetto/grafana-client-3", "prod_url": "http://localhost:3003" }
}
```

| Поле | Что это | Куда идёт |
|---|---|---|
| ключ (`client-2`) | id клиента | из него делаются имена: `client-2-dev`, `client-2-prod` |
| `title` | человеческое название | название папки в Grafana |
| `repo` | репозиторий на GitHub | превращается в `https://github.com/kmetto/grafana-client-2` |
| `prod_url` | **адрес Grafana клиента** | туда Terraform идёт настраивать prod |

Этот файл читают **и скрипты, и Terraform**. Больше нигде список клиентов не пишется (кроме docker-compose, см. ниже).

---

## 7. `docker-compose.yml` — локальные Grafana

Четыре контейнера из одного шаблона:

| Контейнер | Порт | Кто это |
|---|---|---|
| `grafana-dev` | 3000 | наша dev |
| `grafana-client-1` | 3001 | prod клиента 1 |
| `grafana-client-2` | 3002 | prod клиента 2 |
| `grafana-client-3` | 3003 | prod клиента 3 |

⚠️ Порты здесь и `prod_url` в `clients.json` должны совпадать. Друг о друге файлы не знают — следим руками.

Для **реального** клиента контейнер не нужен: у него своя Grafana, в `clients.json` просто пишем её адрес (`"prod_url": "https://grafana.acme.com"`).

Запуск: `docker compose up -d`.

---

## 8. Terraform — зачем и как

### Зачем

Repository в каждой Grafana нужно **создать**. Можно руками в UI (Administration → Provisioning), можно `curl`-ом, а можно Terraform. Terraform удобен тем, что:

- описываешь, **как должно быть**, а он сам решает, что создать/изменить/удалить;
- `terraform plan` **заранее показывает**, что изменится;
- видит, если кто-то поменял настройки руками.

Terraform ходит в **тот же API Grafana**, что и UI. Поэтому Grafana должна быть **запущена** до `terraform apply`.

### Терраформ трогает только Repository

Дашборды Terraform **не трогает** — ими занимается Git Sync. Terraform только создаёт/меняет «провода» (Repository).

### Модуль `terraform/modules/git-sync-repo`

«Рецепт одного Repository». На вход: `uid`, `title`, `repo_url`, `branch`, `workflows`, `github_token`. Сам не знает ни про dev, ни про клиентов — просто кирпичик, который используют `dev/` и `client-prod/`.

### `terraform/dev/` — [будет]

Одна Grafana (dev), в ней по Repository **на каждого клиента** — циклом по `clients.json`:

```hcl
module "client" {
  for_each  = local.clients                  # для каждого клиента из clients.json
  uid       = "${each.key}-dev"              # client-1-dev, client-2-dev, …
  title     = each.value.title               # папка "Client 1", …
  repo_url  = "https://github.com/${each.value.repo}"
  branch    = "dev"
  workflows = ["write"]                      # Save = коммит
}
```

Один запуск — настроены все клиенты в dev.

### `terraform/client-prod/` — [будет]

Тут сложнее. Terraform ходит в Grafana через **провайдер** — это настройка «по какому адресу идти». У каждого клиента **свой адрес**. А Terraform **не умеет создавать провайдеры в цикле**.

Поэтому код написан для **одного клиента** и запускается **отдельно для каждого**. Какой клиент сейчас — говорит **workspace**.

**Workspace** = имя текущего запуска + отдельный файл состояния под это имя. Как ветки в git: код один, состояние у каждого своё.

```hcl
locals {
  client = lookup(local.clients, terraform.workspace, null)
  # workspace "client-2" → нашли в clients.json запись client-2
}

provider "grafana" {
  url = local.client.prod_url        # → http://localhost:3002
}

module "client" {
  uid       = "${terraform.workspace}-prod"  # → client-2-prod
  branch    = "main"
  workflows = []                             # read-only
}
```

Защита: если запустить без клиента (workspace `default`) или с несуществующим — Terraform остановится с ошибкой и списком допустимых клиентов.

### Сколько раз запускать

- **dev** — один `apply` на всех клиентов.
- **prod** — один `apply` **на каждого** клиента.

Это не страшно: prod клиента настраивается **один раз** при подключении клиента. Дальше дашборды едут через Git Sync, Terraform не нужен. Часто запускается только dev.

### `scripts/tf.sh` — как запускать Terraform — [будет]

Не надо помнить флаги и workspace — всё делает обёртка:

```bash
./scripts/tf.sh dev plan                      # что изменится в dev
./scripts/tf.sh dev apply                     # применить для dev

./scripts/tf.sh client-prod client-2 plan     # что изменится у клиента 2
./scripts/tf.sh client-prod client-2 apply    # применить для клиента 2
```

`tf.sh` берёт токен и пароль из `.env` и передаёт в Terraform. В файлы они не пишутся.

---

## 9. State — память Terraform

### Что это

`terraform.tfstate` — файл, где Terraform записывает **«что я создал и как оно выглядело»**. По нему он понимает, что строчка в коде = вот этот конкретный объект в Grafana.

- У `dev` — один файл: `terraform/dev/terraform.tfstate`.
- У `client-prod` — по файлу на клиента: `terraform/client-prod/terraform.tfstate.d/client-2/terraform.tfstate`.
- `terraform.tfstate.backup` — предыдущая версия, Terraform сохраняет её сам перед каждой записью.

### Когда появляется

Не при `init`, а при первой команде, которая что-то записывает: `apply` или `import`. `plan` ничего не записывает.

### Важное

- В state **только** то, что описано в коде и создано/импортировано Terraform. Это не «слепок всей Grafana».
- Токен GitHub в state **не попадает** (он помечен как write-only).
- State в `.gitignore`, в git не коммитим.
- Если state потерять — Terraform «забудет» про объекты. Они останутся в Grafana, но `apply` упадёт с «уже существует». Лечится `import` (ниже).
- Для команды state хранят не локально, а в S3 / Azure Blob (блок `backend` в Terraform). Сейчас — локально.

---

## 10. Import — если объект уже есть, а Terraform о нём не знает

Terraform ищет объекты **только через state**. Если Repository создан руками (или state потерялся), Terraform думает, что его нет, пытается создать — и получает ошибку «уже существует».

`terraform import` говорит Terraform: «вот этот объект в Grafana — это вот этот ресурс в коде, запиши себе».

```bash
terraform import <адрес ресурса в коде> <id объекта в Grafana>
```

Что происходит:
1. Terraform находит ресурс в коде по адресу (код должен уже быть написан).
2. Через провайдер делает `GET` объекта в Grafana по id.
3. Записывает его в state.
4. В Grafana **ничего не меняет**, код **не пишет**.

После импорта первый `plan` может показать разницу между кодом и реальностью — первый `apply` её выровняет.

Одна команда = один ресурс. Если ресурсов много — пишут блоки `import { to = … id = … }` в коде, они применяются все разом за один `apply`.

---

## 11. Как всё поднять с нуля

```bash
cp .env.example .env              # 1. вписать GITHUB_TOKEN
./scripts/bootstrap-repos.sh      # 2. создать репо клиентов (если их нет)
docker compose up -d              # 3. поднять Grafana
./scripts/tf.sh dev apply         # 4. подключить dev ко всем клиентам        [будет]
for c in client-1 client-2 client-3; do
  ./scripts/tf.sh client-prod $c apply   # 5. подключить prod каждого клиента  [будет]
done
./scripts/verify.sh               # 6. проверить, что всё синхронизировалось   [будет]
```

**Токен GitHub** (fine-grained PAT) должен иметь доступ ко **всем** репо клиентов. Права: Contents RW, Pull requests RW, Webhooks RW, Administration R, Metadata R. Где менять: github.com/settings/personal-access-tokens → токен → Edit → Repository access.

---

## 12. Как работать каждый день

1. Открыть dev: http://localhost:3000 → папка нужного клиента.
2. Создать / поменять дашборд → **Save**. Это коммит в репо клиента, ветка `dev`.
3. Когда готово к показу клиенту — PR в репо клиента:
   ```bash
   gh pr create -R kmetto/grafana-client-2 --base main --head dev --fill
   gh pr merge  -R kmetto/grafana-client-2 dev --merge
   ```
4. Через ≤30 секунд дашборд в Grafana клиента (http://localhost:3002).

Откатить у клиента — `git revert` в `main` его репо.

---

## 13. Как добавить нового клиента

1. Дописать в `clients.json`:
   ```json
   "client-4": { "title": "Client 4", "repo": "kmetto/grafana-client-4", "prod_url": "http://localhost:3004" }
   ```
2. (Только для POC) добавить сервис `grafana-client-4` на порт 3004 в `docker-compose.yml` → `docker compose up -d`.
3. `./scripts/bootstrap-repos.sh` — создаст репо.
4. Дать токену доступ к новому репо.
5. `./scripts/tf.sh dev apply` — появится папка "Client 4" в dev.
6. `./scripts/tf.sh client-prod client-4 apply` — подключится prod клиента 4.

---

## 14. Грабли, на которые уже наступили

- **Сменил пароль admin в UI → всё сломалось с 401.** Скрипты и Terraform берут пароль из `.env`. Поменял пароль — поменяй и в `.env`. После нескольких неверных попыток Grafana **блокирует вход на 5 минут**, и каждая новая неверная попытка продлевает блокировку. Не долбить — подождать.
- **Одинаковый uid дашборда у двух клиентов** → конфликт в общей dev Grafana.
- **Дашборд не попал в git** → он не в папке клиента.
- **Изменения не доехали в prod** → подождать 30 секунд; проверить, что PR смержен в `main`.

---

## 15. Что сделать для реальных клиентов (после POC)

- Вместо одного общего токена — **GitHub App** + **Connection** в каждой Grafana.
- Вместо `admin:admin` — **токены service account**, свой для каждой Grafana клиента.
- **State в S3 / Azure Blob**, а не на ноутбуке.
- Запуск Terraform из **CI** (GitHub Actions с matrix по клиентам), а не руками.
