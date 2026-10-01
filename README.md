# Лаборатория TestY в Kubernetes

Воспроизводимый стенд TestY TMS 2.1.3 (YADRO) на шести виртуальных машинах Debian 12. Тот же плейбук поддерживает Ubuntu 24.04: ветка выбирается по `ansible_distribution`. Кластер собирает kubeadm. Снаружи нет облачного балансировщика: MetalLB в режиме L2 отдаёт один VIP, и на него смотрит Service Envoy Gateway. Приложение, PostgreSQL, Redis, Celery и воркер уведомлений работают на трёх worker-узлах. Data plane Envoy стоит только на двух gateway-узлах. Метрики собирает kube-prometheus-stack, access-логи Fluentd отправляет в Loki, Grafana показывает и то и другое.

Кластер в этом репозитории не поднимался: плейбук рассчитан на уже созданные ВМ и отсюда по SSH не запускался. Файл `~/.kube/config` не читается и не пишется. Kubeconfig лаборатории — `.kube/lab.config`, каталог в `.gitignore`.

Образы TestY собираются на машине оператора из публичного тега `release/2.1.3` (`3544c0f34640443c499fde2f9a52be30c863c519`). Приватные реестры не используются. Секреты генерируются при деплое и в git не попадают. Токенов API Proxmox в репозитории нет.

## Архитектура

```text
браузер или curl
        |  HTTPS, VIP MetalLB, testy.local и api.testy.local
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

Узлы kubeadm:

| Роль | Число | Метка и taint |
| --- | --- | --- |
| control-plane | 1 | стандартный taint control-plane |
| workers | 3 | `testy.yadro.dev/pool=app` |
| gateway | 2 | `testy.yadro.dev/pool=gateway` и taint `testy.yadro.dev/pool=gateway:NoSchedule` |

Поды приложения и наблюдаемости не имеют toleration на gateway-taint, поэтому планировщик ставит их на workers. Data plane Envoy имеет и nodeSelector, и toleration, поэтому стоит только на gateway-узлах. Контроллер Envoy Gateway остаётся на workers. Calico, speaker MetalLB, Fluentd и node-exporter — DaemonSet, у них есть toleration, они есть и на gateway.

CNI — Calico, pod CIDR `192.168.0.0/16`. kube-proxy в режиме iptables: в Kubernetes 1.37 режим IPVS объявлен устаревшим. Диски подов — local-path provisioner, StorageClass по умолчанию.

## Технологии и версии

Версии зафиксированы в `ansible/group_vars/all.yml`.

| Компонент | Версия |
| --- | --- |
| ОС узлов | Debian 12 (bookworm). Ubuntu 24.04 (noble) — тот же плейбук |
| Kubernetes | v1.37.0 |
| kubeadm, kubelet, kubectl | пакет `1.37.0-1.1` из `pkgs.k8s.io`, канал `v1.37` |
| cri-tools | `1.37.0-1.1` |
| kubernetes-cni | `1.9.1-1.1` |
| containerd | Debian 12: `1.6.20~ds1-1+deb12u3` (bookworm). Ubuntu 24.04: `2.2.1-0ubuntu1~24.04.3` (noble-updates) |
| Calico | v3.32.2 |
| MetalLB | chart и приложение 0.16.1, режим L2 |
| local-path-provisioner | v0.0.37 |
| Helm | v3.22.0 |
| Envoy Gateway (chart `gateway-helm`) | v1.9.2 |
| kube-prometheus-stack | 91.8.2 |
| Prometheus | v3.15.0-distroless |
| Prometheus Operator | v0.94.1 |
| Alertmanager | v0.34.1 |
| Grafana | 13.2.3 |
| Loki (chart / образ) | chart 6.55.0 / образ `grafana/loki:3.7.8` |
| Fluentd | `fluent/fluentd:v1.19.3-debian-2.4` плюс gem `fluent-plugin-grafana-loki` 1.3.0 |
| TestY | 2.1.3, тег `release/2.1.3` |
| PostgreSQL | `postgres:14.5-alpine` |
| PgBouncer | `edoburu/pgbouncer:1.22.1-p0` |
| Redis | `redis:7.4.6-alpine` |
| nginx UI и sidecar | `nginxinc/nginx-unprivileged:1.27.5-alpine` |
| kubeconform | v0.8.0 |

Пакеты Kubernetes сверены с индексом `https://pkgs.k8s.io/core:/stable:/v1.37/deb/Packages`. Это общий deb-репозиторий, не набор Ubuntu noble: одна строка `deb https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /` ставится и на Debian 12, и на Ubuntu 24.04. В индексе есть `1.37.0-1.1` и `1.37.1-1.1`; пин остаётся `1.37.0-1.1`. Зависимости kubelet `1.37.0-1.1` — `iptables`, `kubernetes-cni`, `mount`, `util-linux`, `libc6`. containerd Debian сверен с `bookworm/main/binary-amd64`: `1.6.20~ds1-1+deb12u3`. В `bookworm-security` лежит более старый `1.6.20~ds1-1+deb12u2`, в `bookworm-updates` и `bookworm-backports` пакета containerd нет. Пин Ubuntu сверен с `noble-updates`: `2.2.1-0ubuntu1~24.04.3`.

Стек TestY совпадает с `docker-compose.yml` релиза: backend (gunicorn + uvicorn), frontend, PostgreSQL, PgBouncer, Redis, Celery (`worker -B`) и `runworker notifications`.

## Виртуальные машины в Proxmox

Плейбук не создаёт ВМ и не ходит в API Proxmox. Ниже план этих машин. Все шесть висят на одном мосту `vmbr0`, подсеть `192.168.15.0/24`, шлюз `192.168.15.1`.

| Имя | Роль | vCPU | RAM | Диск | IP |
| --- | --- | --- | --- | --- | --- |
| k8s-testy-cp | control-plane | 2 | 4 ГиБ | 40 ГиБ | 192.168.15.120 |
| k8s-testy-w1 | worker | 4 | 8 ГиБ | 80 ГиБ | 192.168.15.121 |
| k8s-testy-w2 | worker | 4 | 8 ГиБ | 80 ГиБ | 192.168.15.122 |
| k8s-testy-w3 | worker | 4 | 8 ГиБ | 80 ГиБ | 192.168.15.123 |
| k8s-testy-gw1 | gateway | 2 | 4 ГиБ | 40 ГиБ | 192.168.15.124 |
| k8s-testy-gw2 | gateway | 2 | 4 ГиБ | 40 ГиБ | 192.168.15.125 |
| VIP MetalLB | не интерфейс ВМ |  |  |  | 192.168.15.126 |

Образ — Debian 12. Пользователь — `m.temerov`. Имена и адреса — `k8s-testy-cp` … `k8s-testy-gw2` и VIP `192.168.15.120`–`192.168.15.126` из таблицы. У каждой ВМ свой статический IPv4 на `vmbr0`, диск virtio, включённый в параметрах ВМ QEMU Guest Agent. Имя ВМ и hostname гостя совпадают с именем в инвентаре: kubeadm называет узел этим именем.

Cloud-init в интерфейсе Proxmox: пользователь `m.temerov`, публичный SSH-ключ, DNS, адрес и шлюз из таблицы. Дополнительный сниппет, без токена API:

```yaml
#cloud-config
hostname: k8s-testy-cp
manage_etc_hosts: true
users:
  - name: m.temerov
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA_ПУБЛИЧНЫЙ_КЛЮЧ lab
packages:
  - qemu-guest-agent
  - chrony
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now chrony
  - swapoff -a
  - sed -i '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
```

Для остальных пяти машин меняют только `hostname`. Плейбук всё равно выставляет hostname из инвентаря, гасит swap, ставит и запускает chrony и qemu-guest-agent.

Адрес `192.168.15.126` не добавляют ни на один интерфейс и не отдают по DHCP. MetalLB отвечает на ARP за него с узлов gateway. Это и есть запасной IP под VIP.

## Без Proxmox

Достаточно любых шести машин Debian 12 в одной L2-сети: статические адреса, общий SSH-ключ, sudo без пароля, swap выключен. Те же шаги подходят для Ubuntu 24.04. Имена и адреса записывают в инвентарь. Мост, cloud-init и гостевой агент нужны только если машины живут в Proxmox.

Команду `make deploy` запускают с отдельной машины Debian 12, Ubuntu 24.04 или macOS, с которой есть SSH на все шесть. Это не седьмой узел. На Debian и Ubuntu плейбук ставит пакеты через apt, в том числе Docker, и скачивает Helm и kubectl. На macOS apt-get не вызывается: `docker`, `helm` и `kubectl` уже должны быть в PATH, иначе плейбук останавливается и называет недостающую программу. С машины оператора нужен исходящий HTTPS к GitLab YADRO, Docker Hub, Quay, GitHub, `pkgs.k8s.io` и репозиториям Helm.

## Инвентарь

Файл лаборатории — `ansible/inventory/hosts.ini`. Рядом `hosts.example.ini` с теми же именами и адресами.

| Имя в инвентаре | Группа | `ansible_host` |
| --- | --- | --- |
| `k8s-testy-cp` | `control_plane` | `192.168.15.120` |
| `k8s-testy-w1` | `workers` | `192.168.15.121` |
| `k8s-testy-w2` | `workers` | `192.168.15.122` |
| `k8s-testy-w3` | `workers` | `192.168.15.123` |
| `k8s-testy-gw1` | `gateways` | `192.168.15.124` |
| `k8s-testy-gw2` | `gateways` | `192.168.15.125` |

`ansible_user` — `m.temerov`. `metallb_vip` — `192.168.15.126`. `ui_host` — `testy.local`, `api_host` — `api.testy.local`.

`ansible_ssh_private_key_file` не задан. OpenSSH сам берёт ключ по умолчанию: агент, затем `~/.ssh/id_ed25519` или `~/.ssh/id_rsa`. Путь к приватному ключу в git не записывают. Имя узла kubeadm — это имя в инвентаре (`k8s-testy-cp` и остальные).

## Gateway API и MetalLB

Реализация: **Envoy Gateway v1.9.2**.

- `GatewayClass` `eg` в `k8s/gateway/gateway.yaml`
- `Gateway` `testy` в namespace `testy`: HTTP/80, HTTPS/443 для `testy.local` и HTTPS/443 для `api.testy.local`
- `HTTPRoute` `http-to-https` — редирект 301
- `HTTPRoute` `testy-ui` и `testy-api`
- `EnvoyProxy` `testy-proxy` — Service `LoadBalancer`, `externalTrafficPolicy: Local`, 2 реплики, nodeSelector и toleration gateway-узлов, PDB `minAvailable: 1`

Плейбук подставляет аннотацию `metallb.universe.tf/loadBalancerIPs` из `metallb_vip`. Поле `loadBalancerIP` не задаётся: MetalLB 0.16 не принимает его вместе с этой аннотацией. Пул MetalLB — этот адрес с маской `/32`. L2Advertisement ограничен узлами с меткой gateway. Speaker MetalLB терпит taint gateway, контроллер сидит на workers.

TLS терминируется на Gateway. CA и сертификат с SAN обоих имён создаёт `scripts/generate-tls.sh` в `.secrets/tls/`. Повторный деплой сертификат не перевыпускает, пока имена не изменились.

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
ansible-playbook -i ansible/inventory/hosts.ini ansible/deploy.yml
```

`make deploy` выставляет `KUBECONFIG` на `.kube/lab.config`. Повторный запуск идемпотентен: пакеты удерживаются `apt-mark hold`, `kubeadm init` и `kubeadm join` пропускаются, если узел уже в кластере, образы не пересобираются при том же коммите и имени API, `helm upgrade --install` и `kubectl apply` не удаляют PVC, пароли и CA берутся из уже созданных файлов.

Учётные данные лаборатории:

```bash
cat .secrets/lab-credentials.env
```

Там пароль PostgreSQL, Django `SECRET_KEY`, пароль суперпользователя TestY (`admin`) и пароль Grafana (`admin`). Файл создаётся при первом деплое, права `0600`, в git его нет. Пароли не попадают в ConfigMap и в манифесты: приложение и Grafana читают Secret, PostgreSQL монтирует тот же ключ файлом.

CA для curl и браузера: `.secrets/tls/ca.crt`. В `/etc/hosts` машины, с которой открывают UI:

```text
192.168.15.126 testy.local api.testy.local
```

Адрес — это `metallb_vip`, не адрес узла.

## Проверка

```bash
make verify
```

`scripts/verify-cluster.sh` ходит на VIP Gateway по TLS, порт 443. Проверки по порядку: HTML UI с `TestY TMS`, тело API `{"status": "ok"}`, редирект HTTP 301, один target Prometheus запросом `up{job="kubelet"}` со значением не меньше 1, строка access-лога в Loki после curl. Kubeconfig тот же `.kube/lab.config`.

Вручную, подставив свой VIP:

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
curl --fail --cacert .secrets/tls/ca.crt \
  --resolve "testy.local:443:192.168.15.126" \
  "https://testy.local/"
curl --fail --cacert .secrets/tls/ca.crt \
  --resolve "api.testy.local:443:192.168.15.126" \
  "https://api.testy.local/healthcheck/?probe=labmanual"
```

## Prometheus

Запрос, которым пользуется `make verify`:

```promql
up{job="kubelet"}
```

Успех: статус `success` и хотя бы один ряд со значением 1. Сводка по всем целям, её же показывает дашборд `TestY lab metrics`:

```promql
sum by (job) (up)
```

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090
curl -fsS -G 'http://127.0.0.1:19090/api/v1/query' --data-urlencode 'query=up{job="kubelet"}'
```

В Grafana (admin и пароль из `.secrets/lab-credentials.env`) источник Prometheus имеет uid `prometheus`, источник Loki — uid `loki`.

## Логи

Access-лог пишет sidecar `accesslog` в поде backend. Формат строки начинается с `testy-access`. Так сделано потому, что upstream gunicorn с `UvicornWorker` не гарантирует свой `access_log_format`. Fluentd забирает этот поток и текстовый access-лог Envoy. В Loki уходит метка `job=testy-access`.

```bash
export KUBECONFIG="$PWD/.kube/lab.config"
kubectl -n logging port-forward svc/loki 13100:3100
end=$(date +%s)
start=$((end - 900))
curl -fsS -G 'http://127.0.0.1:13100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="testy-access"} |= "testy-access" |= "probe=labmanual"' \
  --data-urlencode "start=${start}" \
  --data-urlencode "end=${end}"
```

Fluentd работает не от root: uid `999` и gid `999` из образа, дополнительная группа `0` нужна, чтобы читать журналы kubelet `root:root` с правами `0640`. Корень файловой системы только для чтения, позиция tail лежит в emptyDir. Init-контейнер от root ставит sticky-бит на `/tmp` (`1777`): Ruby 3.4 не берёт world-writable каталог без него.

## Безопасность

Секреты создаются на деплое (`scripts/generate-credentials.py`, каталог `.secrets`, права `0600`) и кладутся в Secret `testy-secrets` и `lab-grafana-admin`. PostgreSQL 14 читает пароль из файла `POSTGRES_PASSWORD_FILE`. TestY 2.1.3, PgBouncer `edoburu/pgbouncer:1.22.1-p0` и Grafana 13.2.3 оставляют пароль в окружении: образ берёт `SECRET_KEY`, `POSTGRES_PASSWORD`, `SUPERUSER_PASSWORD`, URL Celery и `DB_PASSWORD` только из переменных, а Grafana 13.2.3 не читает `GF_SECURITY_ADMIN_PASSWORD` из файла. Redis без пароля. Кэш и channels этого релиза собирают `redis://REDIS_HOST:REDIS_PORT` и не умеют передать пароль; `requirepass` оборвал бы их. У backend, Celery, notifications, frontend, PostgreSQL, Redis и PgBouncer свой ServiceAccount, `automountServiceAccountToken: false`. Fluentd монтирует токен и в ClusterRole имеет только `get`, `list`, `watch` на `pods` и `namespaces`. Prometheus, оператор и Grafana используют роли chart kube-prometheus-stack: обнаружение целей и чтение ConfigMap дашбордов. Контроллер Envoy Gateway ходит в API своим токеном; у data plane корень ФС не read-only, потому что Envoy пишет UDS, и Envoy Gateway 1.9 сам оставляет `readOnlyRootFilesystem` пустым. Остальные поля data plane — non-root uid 65532, drop `ALL`, seccomp `RuntimeDefault`.

`testy` — Pod Security `restricted`: процессы уже non-root, probes и entrypoint этого не ломают. `envoy-gateway-system` — `baseline`: chart сам запускает контроллер non-root с read-only корнем, а listener 80/443 внутри контейнера сдвинут на 10080/10443. `logging` — `privileged`: Fluentd монтирует hostPath `/var/log`, а `baseline` такой том запрещает. `monitoring` и `metallb-system` остаются `privileged`, потому что node-exporter использует hostNetwork, hostPID и hostPort 9100, а speaker MetalLB — hostNetwork. Init-контейнер Grafana от root выключен: том данных получает fsGroup 472.

В `testy`, `monitoring`, `logging` и `envoy-gateway-system` NetworkPolicy сначала запрещает весь вход и выход. Дальше явно разрешены DNS, Gateway к портам 8080 приложения, скрейп Prometheus (kubelet 10250, node-exporter 9100, kube-system и Loki 3100), Fluentd к API и к Loki, PgBouncer к PostgreSQL, приложение к PgBouncer и Redis. Клиенты снаружи попадают только на порты data plane 10080, 10443, 80 и 443. Отдельное правило пускает вход из подсети узлов `192.168.15.0/24`: Calico применяет политику и к probes kubelet, и к `kubectl port-forward`, без этого `make verify` не дойдёт до Prometheus и Loki.

## Дополнительно

- requests и limits у приложения, Fluentd и значений Helm
- probes, в том числе долгий startup у backend
- PodDisruptionBudget у PostgreSQL, Redis, PgBouncer, backend, Celery, notifications, frontend и у Envoy (`minAvailable: 1`)
- CI: `.github/workflows/manifests.yml` запускает `make lint`

ResourceQuota нет: на этих шести узлах она делает стенд хрупким.

## Необязательная локальная проверка

`make smoke` не является путём стенда. Это один узел minikube на той же машине, где мало памяти, профиль `testy-smoke`, kubeconfig `.kube/smoke.config`. Шесть узлов он не создаёт и kubeconfig экспертного стенда не перезаписывает. В нём нет Celery, notification worker, PgBouncer, Grafana и kube-prometheus-stack. Экспертам он не нужен.

```bash
make smoke
```

## Ограничения

- Кластер этим репозиторием не создавался. `make deploy` рассчитан на шесть уже существующих ВМ Debian 12. Ubuntu 24.04 проходит по той же ветке `ansible_distribution`.
- containerd на Debian 12 — пакет bookworm `1.6.20~ds1-1+deb12u3`, не сборка Ubuntu `2.2.1`. Пакет kubelet от версии containerd не зависит. Сочетание на ВМ отсюда не устанавливалось.
- Один control-plane. Отказ `k8s-testy-cp` останавливает API.
- MetalLB только L2 и только один VIP в той же подсети, что и узлы. Облачного балансировщика нет. Адрес VIP должен быть свободен.
- Calico v3.32.2 — последний релиз на момент фиксации. Проект Calico проверял эту ветку на Kubernetes 1.34–1.36. Отдельной версии под 1.37 не было, поэтому стенд использует v3.32.2 без заявления, что она входит в матрицу тестов Calico.
- kube-proxy зафиксирован в режиме iptables.
- local-path не реплицирует диск: PVC остаётся на том worker, где впервые сел под.
- Backend в одной реплике: миграции выполняются в его entrypoint.
- PVC медиа один на backend, Celery и notifications.
- Сертификат самоподписанный. Для curl нужен `--cacert .secrets/tls/ca.crt`.
- SMTP не настроен.
- Плейбук выключает ufw, если он установлен, иначе режутся API и ARP MetalLB.
- `host_key_checking` в `ansible.cfg` выключен: это лабораторный допуск, не образец для боевой сети.
- Prometheus, Loki и PostgreSQL могут сесть на один worker. Если под Pending, этому worker нужно больше 8 ГиБ.
- Первый деплой долгий: клон TestY, сборка образов и их импорт в containerd.
- Пароли годятся только для этого стенда. Удаление PVC без удаления `.secrets/lab-credentials.env` разъедет пароль и данные PostgreSQL.
- `make smoke` — отдельный одноузловой minikube и не замена `make deploy`.
