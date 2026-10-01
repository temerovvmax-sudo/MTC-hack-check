# Лаборатория TestY в Kubernetes

Воспроизводимый стенд TestY TMS 2.1.3 (YADRO) на шести узлах minikube. Трафик снаружи принимает только Envoy Gateway на двух выделенных узлах. Приложение, PostgreSQL, Redis, Celery и воркер уведомлений работают на трёх worker-узлах. Метрики собирает kube-prometheus-stack, access-логи приложения Fluentd отправляет в Loki, Grafana показывает и то и другое.

Образы TestY собираются на машине из публичного тега `release/2.1.3` (`3544c0f34640443c499fde2f9a52be30c863c519`). Приватные реестры, в том числе `registry.testit.software`, не используются. Секреты генерируются при деплое и в git не попадают.

## Архитектура

```text
браузер или curl
        |  HTTPS testy.local и api.testy.local
        v
Envoy Gateway, 2 реплики, узлы pool=gateway
        |  HTTPRoute testy-ui          HTTPRoute testy-api
        v                              v
frontend (nginx, статика SPA)         sidecar access-log -> gunicorn TestY
                                          |            |
                                          v            v
                                     PostgreSQL    Redis
                                     через PgBouncer
                                     Celery worker + beat
                                     notification worker

Fluentd DaemonSet читает access-лог sidecar и stdout gunicorn/Envoy
        -> Loki -> Grafana
kube-prometheus-stack -> Grafana
```

Узлы:

| Роль | Число | Метка и taint |
| --- | --- | --- |
| control-plane | 1 | стандартный taint control-plane |
| workers | 3 | `testy.yadro.dev/pool=app` |
| gateway | 2 | `testy.yadro.dev/pool=gateway` и taint `testy.yadro.dev/pool=gateway:NoSchedule` |

Поды приложения и наблюдаемости не имеют toleration на gateway-taint, поэтому планировщик ставит их на workers. Data plane Envoy имеет и nodeSelector, и toleration, поэтому стоит только на gateway-узлах. Контроллер Envoy Gateway остаётся на workers.

## Технологии и версии

Версии зафиксированы в `ansible/group_vars/all.yml`. Плейбук ставит именно их.

| Компонент | Версия |
| --- | --- |
| ОС, на которую рассчитан плейбук | Ubuntu 24.04 |
| Kubernetes | v1.37.0 |
| minikube | v1.39.0, driver docker, профиль `testy-lab` |
| kubectl | v1.37.0 |
| Helm | v3.22.0 |
| Envoy Gateway (chart `gateway-helm`) | v1.9.2, контроллер `docker.io/envoyproxy/gateway:v1.9.2` |
| kube-prometheus-stack | 91.8.2 |
| Prometheus | v3.15.0-distroless |
| Prometheus Operator | v0.94.1 (appVersion чарта) |
| Alertmanager | v0.34.1 (значение чарта) |
| Grafana | 13.2.3 |
| Loki (chart / образ) | chart 6.55.0 / образ `grafana/loki:3.7.8` |
| Fluentd | `fluent/fluentd:v1.19.3-debian-2.4` плюс gem `fluent-plugin-grafana-loki` 1.3.0 |
| TestY | 2.1.3, тег `release/2.1.3` |
| PostgreSQL | `postgres:14.5-alpine` |
| PgBouncer | `edoburu/pgbouncer:1.22.1-p0` |
| Redis | `redis:7.4.6-alpine` |
| nginx UI и sidecar | `nginxinc/nginx-unprivileged:1.27.5-alpine` |
| kubeconform | v0.8.0 |

Стек TestY совпадает с `docker-compose.yml` релиза: backend (gunicorn + uvicorn), frontend, PostgreSQL, PgBouncer, Redis, Celery (`worker -B`) и `runworker notifications`.

## Как создаётся кластер

Ansible на localhost вызывает minikube с изолированным kubeconfig. Файл `~/.kube/config` плейбук не читает и не пишет. Все команды идут через `scripts/with-lab-kubeconfig.sh`, который выставляет:

- `KUBECONFIG=<репозиторий>/.kube/lab.config`
- `MINIKUBE_HOME=<репозиторий>/.minikube`

Оба каталога в `.gitignore`. Профиль minikube: `testy-lab`, 6 узлов, по 2 CPU и 3584 МиБ на узел, диск узла 12 ГиБ, CNI kindnet.

## Gateway API

Реализация: **Envoy Gateway v1.9.2**.

Ресурсы:

- `GatewayClass` `eg` в `k8s/gateway/gateway.yaml` (controllerName `gateway.envoyproxy.io/gatewayclass-controller`; chart 1.9.2 класс сам не создаёт)
- `Gateway` `testy` в namespace `testy`: слушатели HTTP/80, HTTPS/443 для `testy.local` и HTTPS/443 для `api.testy.local`
- `HTTPRoute` `http-to-https` — редирект 301 на HTTPS
- `HTTPRoute` `testy-ui` — префикс `/` на сервис frontend
- `HTTPRoute` `testy-api` — префикс `/` на сервис backend
- `EnvoyProxy` `testy-proxy` — NodePort, 2 реплики, nodeSelector и toleration gateway-узлов, PDB `minAvailable: 1`, текстовый access-лог Envoy в stdout

TLS терминируется на Gateway. CA и сертификат с SAN `testy.local` и `api.testy.local` создаёт `scripts/generate-tls.sh` в `.secrets/tls/`. В git их нет. Повторный деплой сертификат не перевыпускает.

## Требования

Проверено как целевая ОС: Ubuntu 24.04. Плейбук сам ставит Docker, kubectl, minikube, Helm и kubeconform.

Минимум, ниже которого плейбук завершается ошибкой и не уменьшает топологию:

- 4 CPU
- 22000 МиБ `MemAvailable` (ориентир для машины — 32 ГиБ RAM)
- 80 ГиБ свободного диска
- исходящий HTTPS к GitLab YADRO, Docker Hub, GitHub, `dl.k8s.io`, репозиториям Helm

Нужны `sudo` и публичная сеть. Ansible ставится отдельно, одной командой apt, потому что именно он запускает остальное.

## Деплой

```bash
sudo apt-get update
sudo apt-get install -y ansible make git
git clone <url-репозитория> testy-lab
cd testy-lab
make deploy
```

Эквивалент без Make:

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
export MINIKUBE_HOME="$PWD/.minikube"
ansible-playbook ansible/deploy.yml
```

Повторный `make deploy` безопасен: minikube start примиряет уже существующий профиль, `helm upgrade --install` и `kubectl apply` идемпотентны, пароли и CA берутся из уже созданных файлов, данные PostgreSQL остаются в PVC.

Учётные данные лаборатории, не чужие секреты:

```bash
cat .secrets/lab-credentials.env
```

Там пароль PostgreSQL, Django `SECRET_KEY`, пароль суперпользователя TestY (`admin`) и пароль Grafana (`admin`). Файл создаётся при первом деплое, права `0600`.

CA для curl: `.secrets/tls/ca.crt`.

## Проверка приложения через Gateway

После `make deploy`:

```bash
make verify
```

Скрипт `scripts/verify-cluster.sh` сам находит IP узла minikube и NodePort сервиса Gateway. Вручную то же самое выглядит так (порты подставятся скриптом; ниже показана форма команды):

```bash
IP="$(minikube ip -p testy-lab)"
# HTTPS_PORT и HTTP_PORT — nodePort портов 443 и 80 сервиса Gateway
curl --fail --cacert .secrets/tls/ca.crt \
  --resolve "testy.local:${HTTPS_PORT}:${IP}" \
  "https://testy.local:${HTTPS_PORT}/"
curl --fail --cacert .secrets/tls/ca.crt \
  --resolve "api.testy.local:${HTTPS_PORT}:${IP}" \
  "https://api.testy.local:${HTTPS_PORT}/healthcheck/?probe=labmanual"
curl -sI --resolve "testy.local:${HTTP_PORT}:${IP}" \
  "http://testy.local:${HTTP_PORT}/"
```

Ожидание:

- UI: HTTP 200 и HTML, в котором есть `TestY TMS`
- API: HTTP 200 и тело `{"status": "ok"}`
- HTTP-слушатель: статус `301` и редирект на `https`

`KUBECONFIG` для minikube и kubectl в этих командах должен быть `.kube/lab.config`, как в `make verify`.

## Prometheus

Запрос, который должен вернуть данные, если хотя бы одна цель жива:

```promql
sum(up)
```

Успех: HTTP-статус API `success` и значение не меньше 1. Разбивка по job, её же показывает дашборд `TestY lab metrics`:

```promql
sum by (job) (up)
```

Проверка без входа в UI:

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090
curl -fsS -G 'http://127.0.0.1:19090/api/v1/query' --data-urlencode 'query=sum(up)'
```

В Grafana (admin и пароль из `.secrets/lab-credentials.env`) источник Prometheus имеет uid `prometheus`, источник Loki — uid `loki`. Дашборды лежат в ConfigMap `testy-lab-dashboards` и подхватываются sidecar.

Порт Grafana внутри кластера: сервис `kube-prometheus-stack-grafana` в namespace `monitoring`.

## Логи

Access-лог пишет sidecar `accesslog` в поде backend. Формат строки:

```text
testy-access remote=<ip> request="GET /healthcheck/?probe=... HTTP/1.1" status=200 ...
```

Так сделано потому, что upstream gunicorn с `UvicornWorker` не гарантирует свой `access_log_format`. В образ всё равно подложен `gunicorn.conf.py` с тем же префиксом `testy-access` и `accesslog = "-"`. Fluentd забирает оба потока, плюс текстовый access-лог Envoy. В Loki уходит метка `job=testy-access`.

После curl через Gateway:

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
kubectl -n logging port-forward svc/loki 13100:3100
curl -fsS -G 'http://127.0.0.1:13100/loki/api/v1/query' \
  --data-urlencode 'query={job="testy-access"} |= "testy-access" |= "probe=labmanual"'
```

Ожидание: непустой `data.result` и строка с этим `probe`. Дашборд `TestY lab logs` показывает `{job="testy-access"} |= "testy-access"`.

Fluentd работает от root и **не** privileged. Root нужен, чтобы читать hostPath `/var/log` узла: файлы CRI часто принадлежат root. Дополнительных capability нет, `privileged: false`. Это записано в манифесте DaemonSet.

## Дополнительно

- namespaces `testy`, `monitoring`, `logging`, `envoy-gateway-system`, Pod Security `baseline`
- requests и limits у приложения, Fluentd и значений Helm
- probes, в том числе долгий startup у backend: первый `migrate` может занять несколько минут
- PodDisruptionBudget у PostgreSQL, Redis, PgBouncer, backend, Celery, notifications, frontend и у Envoy (`minAvailable: 1` при двух репликах)
- frontend и backend sidecar — пользователь nginx (uid 101); gunicorn, Celery и notifications — uid 10001; PostgreSQL — uid 70; Redis — uid 999
- CI: `.github/workflows/manifests.yml` запускает `make lint` (yamllint, `helm template`, kubeconform со схемами Kubernetes 1.37.0)
- локально то же самое: `make lint`
- паспорт решения: `docs/Паспорт.pdf`, исходник `docs/passport.md`

ResourceQuota нет: на шести небольших узлах она делает стенд хрупким без пользы для этой лаборатории.

## Ограничения

- Плейбук не сжимает топологию. Если `MemAvailable` меньше 22 ГиБ, он останавливается до создания кластера.
- Первый деплой долгий: клон TestY, `pip` с git-зависимостями YADRO и `npm ci` frontend.
- Backend в одной реплике: миграции выполняются в его entrypoint. Вторая реплика гоняла бы `migrate` параллельно.
- PVC медиа один на backend, Celery и notifications, поэтому они стоят на одном узле.
- Сертификат самоподписанный, браузер покажет предупреждение. Для curl нужен `--cacert .secrets/tls/ca.crt`.
- SMTP не настроен. Почта в релизе есть, для проверки Gateway она не нужна.
- Это minikube с docker-driver, не промышленный кластер и не облачный load balancer. Снаружи Gateway доступен через NodePort.
- Пароли лаборатории годятся только для этого стенда.
- Удаление PVC без удаления `.secrets/lab-credentials.env` (или наоборот) разъедет пароль и данные PostgreSQL. Чтобы начать заново, удаляйте профиль, PVC и `.secrets` вместе: `minikube delete -p testy-lab` при том же `KUBECONFIG` и `MINIKUBE_HOME`.
