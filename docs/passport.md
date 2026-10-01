# Паспорт решения: лаборатория TestY

Максим Темеров

## 1. Архитектура и стек

Я собрал стенд TestY на шести виртуальных машинах Debian 12, пользователь m.temerov. Тот же плейбук Ansible ставит Ubuntu 24.04: ветка выбирается по ansible_distribution.

Кластер собирает kubeadm. Kubernetes v1.37.0, пакеты kubeadm, kubelet и kubectl 1.37.0-1.1 с pkgs.k8s.io, containerd Debian 1.6.20~ds1-1+deb12u3. CNI — Calico v3.32.2. Один control-plane, три worker с меткой pool=app, два gateway с меткой pool=gateway и taint NoSchedule. На gateway планируется только data plane Envoy.

Облачного балансировщика нет. MetalLB v0.16.1 работает в L2 и отдаёт один VIP 192.168.15.126. Service Envoy Gateway типа LoadBalancer смотрит на этот адрес. Имена testy.local и api.testy.local, TLS терминируется на Gateway.

Приложение — TestY 2.1.3, тег release/2.1.3. Рядом Envoy Gateway v1.9.2, kube-prometheus-stack 91.8.2, Grafana 13.2.3, Fluentd 1.19.3 и Loki 3.7.8. Диски подов — local-path.

[[diagram]]

## 2. Как сделано и как проверить

Инвентарь. Подсеть 192.168.15.0/24, шлюз 192.168.15.1. Узлы k8s-testy-cp .120, w1–w3 .121–.123, gw1–gw2 .124–.125, metallb_vip 192.168.15.126. Путь к приватному ключу я не кладу в git: OpenSSH берёт ключ по умолчанию. Имена kubeadm совпадают с hostname. Проверка: шесть узлов Ready.

kubeadm. Плейбук ставит зафиксированные пакеты, выключает swap, включает chrony, инициализирует control-plane и присоединяет остальные узлы. Если у virtio-диска есть свободное место, без перезагрузки расширяется последний раздел, PV, корневой LV и файловая система. Нет места — шаг пропускается. Повторный запуск не вызывает kubeadm init и join заново.

Calico и пулы. Calico ставится до join, затем узлы получают метки, gateway — taint. Так data plane не смешивается с приложением. Проверка: два узла с taint NoSchedule, поды backend без этого toleration.

MetalLB. Helm 0.16.1, пул из одного адреса /32, L2Advertisement только с узлов gateway. VIP не прописывается на интерфейс ВМ: на ARP отвечает speaker. Проверка: EXTERNAL-IP Service Gateway равен 192.168.15.126, curl по HTTPS на этот адрес.

TestY, два имени и TLS. Публичного образа релиза нет, чужой реестр я не использую. Образ собирается на машине оператора из тега release/2.1.3 и импортируется в containerd. Gateway слушает testy.local и api.testy.local. CA и сертификат с SAN обоих имён лежат в .secrets/tls, в git их нет. Проверка: UI содержит TestY TMS, /healthcheck/ возвращает status ok, HTTP даёт 301.

Наблюдаемость и Grafana. kube-prometheus-stack и Loki ставятся Helm-ом. Grafana смотрит оба источника. Access-лог пишет sidecar, Fluentd забирает его и stdout Envoy в Loki с меткой job=testy-access. Namespace logging — privileged: baseline запрещает hostPath /var/log. Коллектор работает от uid 999 с группой 0, init-контейнер ставит sticky-бит на /tmp, иначе Ruby не стартует. Проверка: PromQL up{job="kubelet"} не меньше одного target со значением 1; после curl LogQL через /loki/api/v1/query_range находит строку testy-access. Те же запросы есть на дашбордах Grafana.

CI. Workflow manifests.yml запускает make lint: yamllint и kubeconform по манифестам и шаблонам Helm. Кластер для этой проверки не нужен.

Безопасность. Пароли создаются при деплое в .secrets с правами 0600 и попадают в Secret. PostgreSQL читает пароль из файла. TestY, PgBouncer и Grafana читают секрет из окружения: эти образы не умеют файл. Redis без пароля, потому что кэш и channels релиза 2.1.3 не передают его. У каждой нагрузки TestY свой ServiceAccount без токена API. Fluentd может только читать pods и namespaces. testy — Pod Security restricted, envoy-gateway-system — baseline, logging, monitoring и metallb-system — privileged только там, где нужен hostPath или hostNetwork. NetworkPolicy по умолчанию закрывает эти четыре namespace; открыты DNS, Gateway к приложению, скрейп, Fluentd к Loki и базы. Вход из 192.168.15.0/24 оставлен: Calico режет probes и port-forward. Проверка: make verify.

Без Proxmox. Те же шесть Debian 12 в одной L2-сети и заполненный инвентарь. Плейбук не вызывает API Proxmox и не хранит токен.

## 3. Разбор

Сильная сторона. Data plane отделён taint-ом, снаружи виден один VIP MetalLB. Имена UI и API — обычные объекты Gateway API, а не отдельный ingress-контроллер.

Трудное решение. У релиза нет публичного образа приложения, а чужой реестр использовать нельзя. Я клонирую тег release/2.1.3 на этапе деплоя: репозиторий маленький, версия воспроизводима. Calico v3.32.2 взят как последний релиз на момент фиксации. Проект проверял его на Kubernetes 1.34–1.36, отдельного релиза под 1.37 не было.

Дальше, если продолжать:

- Второй control-plane. Сейчас отказ одного узла гасит API.
- cert-manager вместо openssl на машине оператора.
- Хранилище с репликацией вместо local-path: PVC сейчас привязан к одному worker.
- Вторая реплика backend после отдельной задачи миграций.

Телеком. TestY — открытая TMS YADRO для проверки оборудования. Стенд показывает лабораторный контур: портал опубликован через Gateway API и MetalLB, узлы data plane отделены от приложения, access-лог доходит до Loki. Это не абонентский трафик и не замена DPI или 5G core.
