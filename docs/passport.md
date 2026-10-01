# Паспорт решения: лаборатория TestY

## 1. Архитектура и стек

Стенд — шесть виртуальных машин Debian 12, пользователь m.temerov. Тот же плейбук поддерживает Ubuntu 24.04. Кластер собирает kubeadm: Kubernetes v1.37.0, пакеты kubeadm, kubelet и kubectl 1.37.0-1.1 с pkgs.k8s.io, containerd Debian 1.6.20~ds1-1+deb12u3. CNI — Calico v3.32.2. Один control-plane, три worker с меткой pool=app, два gateway с меткой pool=gateway и taint NoSchedule. На gateway планируется только data plane Envoy.

Снаружи нет облачного балансировщика. MetalLB v0.16.1 работает в L2: один VIP в той же подсети, Service Envoy Gateway типа LoadBalancer. Имена testy.local и api.testy.local, TLS на Gateway.

TestY 2.1.3 (тег release/2.1.3), Envoy Gateway v1.9.2, kube-prometheus-stack 91.8.2, Grafana 13.2.3, Fluentd 1.19.3 в Loki 3.7.8. Диски — local-path. Кластер этим репозиторием не поднимался и SSH на ВМ не выполнялся.

[[diagram]]

## 2. Как сделано и как проверить

Инвентарь. Подсеть 192.168.15.0/24, шлюз 192.168.15.1. Узлы k8s-testy-cp .120, w1–w3 .121–.123, gw1–gw2 .124–.125, metallb_vip 192.168.15.126, пользователь m.temerov. Путь к приватному ключу не задан: OpenSSH берёт ключ по умолчанию. Имена kubeadm совпадают с hostname.

kubeadm. Плейбук ставит зафиксированные пакеты, выключает swap, включает chrony, инициализирует control-plane и присоединяет остальные узлы. Если у virtio-диска есть свободное место, без перезагрузки расширяется последний раздел, PV, корневой LV и файловая система. Нет места — шаг пропускается. Повторный запуск не вызывает kubeadm init и join заново. Проверка: kubectl get nodes показывает шесть узлов Ready.

Calico и пулы. Calico ставится до join. Затем узлы получают метки, gateway — taint. Проверка: два узла с taint NoSchedule, поды backend без этого toleration.

MetalLB. Helm 0.16.1, пул из одного адреса, L2Advertisement только с узлов gateway. VIP не прописывается на интерфейс ВМ. Проверка: EXTERNAL-IP Service Gateway равен metallb_vip, curl по HTTPS на этот адрес.

TestY и TLS. Образы собираются на машине оператора и импортируются в containerd. CA и сертификат лежат в .secrets/tls, в git их нет. Проверка: UI содержит TestY TMS, /healthcheck/ возвращает status ok, HTTP даёт 301.

Наблюдаемость. kube-prometheus-stack и Loki через Helm, Fluentd читает access-лог. Проверка: PromQL up{job="kubelet"} не меньше одного target со значением 1, после curl LogQL через /loki/api/v1/query_range находит строку testy-access.

Безопасность. Пароли создаются при деплое в .secrets (права 0600) и живут в Secret. PostgreSQL читает пароль из файла. TestY, PgBouncer и Grafana читают секрет из окружения: эти образы не умеют файл. Redis без пароля, потому что кэш и channels релиза 2.1.3 не передают его. У каждой нагрузки TestY свой ServiceAccount без токена API. Fluentd может только читать pods и namespaces. testy — Pod Security restricted, envoy-gateway-system — baseline, logging — privileged из-за hostPath Fluentd, monitoring и metallb-system — privileged из-за hostNetwork node-exporter и speaker. NetworkPolicy по умолчанию закрывает testy, monitoring, logging и envoy-gateway-system; открыты DNS, Gateway к приложению, скрейп, Fluentd к Loki и базы. Вход из 192.168.15.0/24 оставлен: Calico режет probes и port-forward. Кластер этими правками не обновлялся.

Без Proxmox. Те же шесть Debian 12 в одной L2-сети и заполненный инвентарь. Ubuntu 24.04 поддерживается тем же плейбуком. Плейбук не вызывает API Proxmox и не хранит токен.

## 3. Разбор

Сильная сторона. Data plane отделён taint-ом, снаружи виден один VIP MetalLB. Имена UI и API — обычные объекты Gateway API.

Трудное решение. У релиза нет публичного образа приложения, а чужой реестр использовать нельзя. Оставлен клон тега release/2.1.3 на этапе деплоя: репозиторий маленький, версия воспроизводима. Calico v3.32.2 выбран как последний релиз на момент фиксации; проект проверял его на Kubernetes 1.34–1.36, отдельного релиза под 1.37 не было.

Дальше, если продолжать:

- Второй control-plane. Сейчас отказ одного узла гасит API.
- cert-manager вместо openssl на машине оператора.
- Хранилище с репликацией вместо local-path: PVC сейчас привязан к одному worker.
- Вторая реплика backend после отдельной задачи миграций.

Телеком. TestY — открытая TMS YADRO для проверки оборудования. Стенд показывает лабораторный контур: портал опубликован через Gateway API и MetalLB, узлы data plane отделены от приложения, access-лог доходит до Loki. Это не абонентский трафик и не замена DPI или 5G core.
