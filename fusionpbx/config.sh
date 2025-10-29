
# FusionPBX Settings
domain_name=localhost                      # hostname, ip_address or a custom value
system_username=admin                       # default username admin
system_password=random                      # random or a custom value
system_branch=5.4                           # master, 5.4

# Optional Applications
application_transcribe=true                # Speech to Text
application_speech=true                    # Text to Speech
application_device_logs=true               # Log device provision requests
application_dialplan_tools=false           # Add additional dialplan applications
application_edit=false                     # Editor for XML, Provision, Scripts, and PHP
application_sip_trunks=false               # Registration-based SIP trunks


# Database Settings
database_name=fusion_pbx_db                     # Database name (safe characters A-Z, a-z, 0-9)
database_username=fusionpbx                 # Database username (safe characters A-Z, a-z, 0-9)
database_password=12345678                    # random or a custom value (safe characters A-Z, a-z, 0-9)
database_repo=official                      # PostgreSQL official, system
database_version=17                         # requires repo official
database_host=pbx_postgres                     # hostname or IP address
database_port=5432                          # port number
database_backup=false                       # true or false
