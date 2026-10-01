FROM python:3.11.9-alpine

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apk update \
    && apk add --virtual build-deps gcc musl-dev \
    && apk add --no-cache postgresql-dev netcat-openbsd build-base python3-dev libffi-dev git \
    && addgroup -g 10001 -S testy \
    && adduser -u 10001 -S -G testy testy

WORKDIR /testy
COPY requirements/prod.txt requirements/prod.txt
RUN pip install --no-cache-dir -r requirements/prod.txt \
    && apk del build-deps \
    && rm -rf /root/.cache

COPY . /testy
RUN chmod 0755 /testy/scripts/entrypoint.sh \
    && mkdir -p /testy/media /testy/testy-static \
    && chown -R testy:testy /testy

USER testy
EXPOSE 8000
CMD ["serve"]
