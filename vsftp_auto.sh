#!/bin/bash
set -o pipefail

BASE_DIR="/opt/ftp-manager"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
DOCKER_DIR="$BASE_DIR/docker"

IMAGE_NAME="vsftpd-auto:latest"
CONTAINER_NAME="ftp-server-prod"

PASV_MIN=40000
PASV_MAX=40010

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
else
  GREEN=""; BLUE=""; YELLOW=""; CYAN=""; RED=""; NC=""
fi

die(){ echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
ok(){ echo -e "${GREEN}[OK] $1${NC}"; }
info(){ echo -e "${BLUE}[INFO] $1${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $1${NC}"; }

root(){ [ "$EUID" -eq 0 ] || die "Ejecuta con sudo."; }
ip_host(){ ip route get 1 2>/dev/null | awk '{print $7;exit}'; }
pause(){ read -p "Enter para continuar..." ; }

docker_ok(){ command -v docker >/dev/null 2>&1; }
d_exists(){ docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
d_run(){ docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }

n_inst(){ systemctl list-unit-files 2>/dev/null | grep -q "^vsftpd"; }
n_run(){ systemctl is-active --quiet vsftpd 2>/dev/null; }

status(){
  if d_run; then echo -e "${GREEN}ACTIVO (Docker)${NC}"
  elif n_run; then echo -e "${GREEN}ACTIVO (Nativo)${NC}"
  else echo -e "${RED}INACTIVO${NC}"; fi
}

setup_docker_files(){
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$DOCKER_DIR"
  touch "$CONFIG_DIR/users.list"

  # 1. Configuración de VSFTP optimizada para Docker
  cat > "$CONFIG_DIR/vsftpd.conf" <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_enable=YES
pasv_min_port=$PASV_MIN
pasv_max_port=$PASV_MAX
# Importante para que docker logs capture la actividad
xferlog_std_format=NO
log_ftp_protocol=YES
vsftpd_log_file=/var/log/vsftpd.log
xferlog_file=/var/log/vsftpd.log
seccomp_sandbox=NO
EOF

  # 2. Entrypoint: Gestión de usuarios y arranque
  cat > "$DOCKER_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

# Configurar IP Pasiva si viene en variable de entorno
if [ -n "$PASV_ADDRESS" ]; then
    grep -q "pasv_address" /etc/vsftpd/vsftpd.conf || echo "pasv_address=$PASV_ADDRESS" >> /etc/vsftpd/vsftpd.conf
fi

# Crear usuarios desde users.list
while IFS=':' read -r u p; do
  [[ "$u" =~ ^#.*$ ]] && continue
  [ -z "$u" ] && continue
  
  # Si el usuario no existe, lo creamos
  if ! id "$u" &>/dev/null; then
    # Creamos usuario con home fija para mapeo de volúmenes
    useradd -m -d "/home/vsftpd/$u" -s /bin/sh "$u"
    echo "$u:$p" | chpasswd
    
    # Aseguramos directorios y permisos
    mkdir -p "/home/vsftpd/$u/upload"
    # El root del chroot debe ser root:root, la subcarpeta upload es del usuario
    chown root:root "/home/vsftpd/$u"
    chmod 755 "/home/vsftpd/$u"
    chown "$u:$u" "/home/vsftpd/$u/upload"
    
    echo "Usuario $u configurado."
  else
    # Si ya existe (reinicio), actualizamos contraseña por si cambió
    echo "$u:$p" | chpasswd
  fi
done < /etc/vsftpd/users.list

echo "Iniciando VSFTP..."
# Ejecutamos vsftpd
exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf
EOF
  chmod +x "$DOCKER_DIR/entrypoint.sh"

  # 3. Dockerfile: Construcción de la imagen
  cat > "$DOCKER_DIR/Dockerfile" <<EOF
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Instalamos vsftpd y utilidades necesarias
RUN apt-get update && \
    apt-get install -y --no-install-recommends vsftpd iproute2 && \
    rm -rf /var/lib/apt/lists/*

# Preparamos directorios obligatorios para vsftpd
RUN mkdir -p /var/run/vsftpd/empty && \
    mkdir -p /var/log && \
    touch /var/log/vsftpd.log

# Redireccionamos logs a stdout para que "docker logs" funcione
RUN ln -sf /dev/stdout /var/log/vsftpd.log

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 20 21 $PASV_MIN-$PASV_MAX

CMD ["/entrypoint.sh"]
EOF
}

install_docker(){
  root; docker_ok || die "Docker no está instalado."
  setup_docker_files
  info "Construyendo imagen..."
  docker build -t "$IMAGE_NAME" "$DOCKER_DIR" || die "Error construyendo imagen."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null
  info "Creando contenedor..."
  docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p 21:21 -p "${PASV_MIN}-${PASV_MAX}:${PASV_MIN}-${PASV_MAX}" \
    -e PASV_ADDRESS="$(ip_host)" \
    -v "$CONFIG_DIR/vsftpd.conf":/etc/vsftpd/vsftpd.conf \
    -v "$CONFIG_DIR/users.list":/etc/vsftpd/users.list \
    -v "$DATA_DIR":/home/vsftpd \
    "$IMAGE_NAME" >/dev/null
  ok "FTP instalado (Docker)."
}

install_native(){
  root
  warn "Instalación nativa con apt."
  read -p "¿Continuar? (s/n): " c; [[ "$c" != "s" ]] && return
  apt-get update && apt-get install -y vsftpd || die "No se pudo instalar vsftpd."
  cp /etc/vsftpd.conf /etc/vsftpd.conf.bak 2>/dev/null
  cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=$PASV_MIN
pasv_max_port=$PASV_MAX
pasv_address=$(ip_host)
EOF
  systemctl enable --now vsftpd
  ok "FTP instalado (Nativo)."
}

start_srv(){
  root
  if d_exists; then docker start "$CONTAINER_NAME" >/dev/null; ok "Iniciado (Docker)."; return; fi
  if n_inst; then systemctl start vsftpd; ok "Iniciado (Nativo)."; return; fi
  die "No hay instalación detectada."
}

stop_srv(){
  root
  if d_run; then docker stop "$CONTAINER_NAME" >/dev/null; ok "Detenido (Docker)."; return; fi
  if n_run; then systemctl stop vsftpd; ok "Detenido (Nativo)."; return; fi
  warn "Ya estaba detenido."
}

create_user(){
  root
  local u="$1" p="$2"
  [ -z "$u" ] && read -p "Usuario: " u
  [ -z "$p" ] && read -s -p "Contraseña: " p && echo ""
  if d_exists; then
    mkdir -p "$CONFIG_DIR"; touch "$CONFIG_DIR/users.list"
    sed -i "/^$u:/d" "$CONFIG_DIR/users.list"
    echo "$u:$p" >> "$CONFIG_DIR/users.list"
    d_run && docker restart "$CONTAINER_NAME" >/dev/null
    ok "Usuario $u creado/actualizado (Docker)."
    return
  fi
  if n_inst; then
    id "$u" &>/dev/null && echo "$u:$p" | chpasswd || (useradd -m "$u" && echo "$u:$p" | chpasswd)
    ok "Usuario $u creado/actualizado (Nativo)."
    return
  fi
  die "No hay instalación detectada."
}

logs_tail(){
  root
  if d_exists; then info "Logs Docker (Ctrl+C)"; docker logs --tail 100 -f "$CONTAINER_NAME"; return; fi
  if n_inst; then info "Logs Nativo (Ctrl+C)"; journalctl -u vsftpd -n 100 -f; return; fi
  die "No hay instalación detectada."
}

logs_date(){
  root
  local date="$1"
  [ -z "$date" ] && read -p "Fecha (YYYY-MM-DD): " date
  [ -z "$date" ] && die "Fecha vacía."
  if d_exists; then docker logs "$CONTAINER_NAME" 2>/dev/null | grep "$date" || warn "Sin coincidencias."; return; fi
  if n_inst; then journalctl -u vsftpd --since "$date 00:00:00" --until "$date 23:59:59"; return; fi
  die "No hay instalación detectada."
}

logs_type(){
  root
  local t="$1"
  [ -z "$t" ] && read -p "Tipo (ERROR/FAIL/LOGIN...): " t
  [ -z "$t" ] && die "Tipo vacío."
  if d_exists; then docker logs "$CONTAINER_NAME" 2>/dev/null | grep -i "$t" || warn "Sin coincidencias."; return; fi
  if n_inst; then journalctl -u vsftpd 2>/dev/null | grep -i "$t" || warn "Sin coincidencias."; return; fi
  die "No hay instalación detectada."
}

logs_menu(){
  while true; do
    clear
    echo -e "${BLUE}=========== LOGS FTP ===========${NC}"
    echo "1) Logs en directo"
    echo "2) Logs de HOY"
    echo "3) Logs por FECHA"
    echo "4) Logs por TIPO"
    echo "5) Volver"
    read -p "Opción: " o
    case "$o" in
      1) logs_tail ;;
      2) logs_date "$(date +%Y-%m-%d)"; pause ;;
      3) logs_date; pause ;;
      4) logs_type; pause ;;
      5) return ;;
      *) echo -e "${RED}Opción inválida${NC}"; sleep 1 ;;
    esac
  done
}

uninstall_all(){
  root
  read -p "¿Eliminar FTP? (s/n): " c; [[ "$c" != "s" ]] && return
  docker_ok && docker rm -f "$CONTAINER_NAME" 2>/dev/null && docker rmi "$IMAGE_NAME" 2>/dev/null
  n_inst && systemctl stop vsftpd 2>/dev/null && apt-get remove --purge -y vsftpd 2>/dev/null
  read -p "¿Borrar $BASE_DIR? (s/n): " clean; [[ "$clean" == "s" ]] && rm -rf "$BASE_DIR"
  ok "Eliminado."
}

help_menu(){
  echo "Uso: $0 [opciones]"
  echo ""
  echo "Instalar:"
  echo "  --install-docker"
  echo "  --install-native"
  echo ""
  echo "Gestión:"
  echo "  --start | --stop | --status"
  echo "  --create-user <user> <pass>"
  echo ""
  echo "Logs:"
  echo "  --logs"
  echo "  --logs-tail"
  echo "  --logs-date YYYY-MM-DD"
  echo "  --logs-type ERROR"
  echo ""
  echo "Otros:"
  echo "  --uninstall"
  echo "  --help"
}

if [ -n "$1" ]; then
  case "$1" in
    --install-docker) install_docker ;;
    --install-native) install_native ;;
    --start) start_srv ;;
    --stop) stop_srv ;;
    --status) echo -e "Estado: $(status)" ;;
    --create-user) create_user "$2" "$3" ;;
    --logs) logs_menu ;;
    --logs-tail) logs_tail ;;
    --logs-date) logs_date "$2" ;;
    --logs-type) logs_type "$2" ;;
    --uninstall) uninstall_all ;;
    --help) help_menu ;;
    *) die "Opción desconocida. Usa --help." ;;
  esac
  exit 0
fi

root
while true; do
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}          FTP MANAGER                   ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo -e "IP Servidor : ${CYAN}$(ip_host)${NC}"
  echo -e "Estado FTP  : $(status)"
  echo -e "${BLUE}========================================${NC}"
  echo -e "1) ${GREEN}Instalar (Docker)${NC}"
  echo -e "2) ${YELLOW}Instalar (Nativo)${NC}"
  echo "3) Iniciar"
  echo "4) Detener"
  echo "5) Crear usuario"
  echo "6) Logs"
  echo -e "7) ${RED}Desinstalar${NC}"
  echo "8) Salir"
  read -p "Opción: " op
  case "$op" in
    1) install_docker; pause ;;
    2) install_native; pause ;;
    3) start_srv; pause ;;
    4) stop_srv; pause ;;
    5) create_user; pause ;;
    6) logs_menu ;;
    7) uninstall_all; pause ;;
    8) exit 0 ;;
    *) echo -e "${RED}Opción inválida${NC}"; sleep 1 ;;
  esac
done
