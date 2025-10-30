# How to update password user

docker exec -it pbx_fusion bash -lc '
set -e
DBH=pbx_postgres; DBP=5432; DBN=fusion_pbx_db; DBU=fusionpbx;
DOMAIN=$(psql -t -A -h "$DBH" -p "$DBP" -U "$DBU" -d "$DBN" -c "select domain_uuid from v_domains limit 1;")
SALT=$(php -r "echo trim(file_get_contents(\"/proc/sys/kernel/random/uuid\"));")
HASH=$(php -r "echo md5(\"$SALT\".\"'"INSERT PASSWORD HERE"'\");")
psql -h "$DBH" -p "$DBP" -U "$DBU" -d "$DBN" -c "
update v_users
set salt = '\''$SALT'\'',
         password = '\''$HASH'\''
where username = '\''admin'\''
and domain_uuid = '\''$DOMAIN'\'';
"
echo "Password set for admin@$DOMAIN"

# How to update domain name

docker exec -it pbx_postgres psql -U fusionpbx -d fusion_pbx_db -c \
 "update v_domains set domain_name='INSERT DOMAIN NAME HERE' where domain_uuid='a0045c85-d299-4a59-92a5-6ea186c26e6f';"
UPDATE 1

# Detect local ip v4

Linux: ip a | grep inet
mac os: ipconfig getifaddr en0
windows: Get-NetIPAddress | Where-Object {$\_.AddressFamily -eq "IPv4"}
