# Migración de servicios a Docker secrets

Guía general para quitar las credenciales de los `.env` y moverlas a Docker
secrets (rotando las contraseñas expuestas). Aplica a los servicios de este
repo; los ya migrados son **Nginx Proxy Manager**, **MariaDB** y **Vaultwarden**.

## El ciclo, por servicio

Cada servicio se migra en este orden:

### 1. Preparar el compose

- Reemplazar cada credencial del `.env` por una variable que apunte a un
  archivo: `<VAR>__FILE=/run/secrets/<name>` (o `*_FILE` según el formato del
  servicio; NPM usa `DB_MYSQL_*__FILE`, Forgejo usa
  `FORGEJO__database__*__FILE`, Vaultwarden usa `DATABASE_URL_FILE`, ...).
- Añadir un bloque `secrets:` **bajo el servicio** (grant per-service). Sin
  esto, compose despliega sin error pero NO monta los archivos — incidente NPM.
- Añadir el bloque `secrets:` a nivel de archivo (top-level) con
  `file: "${PATH_TO_SECRETS}/<Servicio>/<name>"`.

### 2. Crear los secretos en el servidor

```bash
./Security/init-secrets.sh <Servicio> <secreto1> [secreto2 ...] @db
```

- `<name>` — valor plano (se pega dos veces, nunca se imprime).
- `<name>@mysql` — URL `mysql://user:pass@host:port/db` generada para ti.
- `@db` — juego completo de credenciales de BD: pregunta nombre de BD (por
  defecto `<servicio>_db`), usuario (por defecto `<servicio>_user`) y
  contraseña, y escribe `db_mysql_name`, `db_mysql_user`, `db_mysql_password`
  y `db_mysql_url` en `$PATH_TO_SECRETS/<Servicio>/`.

Ejemplos reales:

```bash
./Security/init-secrets.sh Forgejo @db
./Security/init-secrets.sh NginxProxyManager @db
./Security/init-secrets.sh Vaultwarden admin_token db_url@mysql domain
./Security/init-secrets.sh Cloudflare tunnel_token
./Security/init-secrets.sh WireGuard wg_password
```

### 3. Aplicar la BD (solo si el servicio usa MariaDB)

```bash
./Security/init-secrets.sh --update-database <Servicio>
```

Ejecuta `ALTER USER ... IDENTIFIED BY` + `GRANT` contra MariaDB leyendo los
`db_mysql_*` creados por `@db` (sin pedir nada, sin pasar la contraseña por
la línea de comandos). MariaDB no tiene dual-password, así que el cambio es
**inmediato**: se corre justo después de `@db` y justo antes del redeploy.
Con `--dry-run` solo imprime el SQL.

### 4. Desplegar y verificar

- En Portainer: en el stack del servicio, quitar las variables viejas
  (`MYSQL_*`, contraseñas en `environment:`), asegurar que exista
  `PATH_TO_SECRETS`, y Update/Redeploy.
- Verificar:
  - el archivo montado: `docker exec <contenedor> cat /run/secrets/<name>`;
  - `docker logs <contenedor>` sin errores de credenciales/BD;
  - login en la UI y datos intactos.

## Reglas de oro (aprendidas en el incidente de NPM)

- **Los secrets top-level no se montan solos**: cada servicio debe pedirlos
  con `secrets:` bajo el servicio. Compose no avisa; despliega igual.
- **No hagas redeploy desde una URL servida por el propio NGINX**: el redeploy
  tumba la conexión con la que estás entrando. Usa la IP directa
  (`http://<server>:9000`).
- **Ventana corta entre `--update-database` y el redeploy**: el contenedor en
  marcha conserva la contraseña vieja en memoria; al cambiar en MariaDB, todo
  lo que reconecte con la vieja falla hasta que se recrea.

## Orden de migración

1. **Forgejo** (compose ya migrado; falta aplicar: `@db`, `--update-database`, redeploy)
2. **Portainer**
3. **NextCloud**
4. **Collabora**
5. **n8n**
6. **wg-easy**
7. **pihole**
8. **cloudflared**
9. **borg-web-ui**
10. **samba**
11. **syncthing**
12. **filebrowser**
13. **heimdall**
14. **goaccess**
15. **fmd**
16. **zerotier**

## Post-migración

- Apuntar **Syncthing** a `.secrets/`.
- Revisar las configuraciones de **backup** para que incluyan `.secrets/`.
- Actualizar el README de `init-secrets` y crear el de `sync-db-users`.
