{% from '_lib.hcl' import authproxy_group, continuous_reschedule with context -%}

job "rocketchat" {
  datacenters = ["dc1"]
  type = "service"
  priority = 30

  group "db" {
    task "mongo" {
      driver = "docker"
      config = {
        image = "mongo:3.2"
        volumes = [
          "${liquid_volumes}/rocketchat/mongo/data:/data/db",
        ]
        args = ["mongod", "--smallfiles", "--replSet", "rs01"]
        labels {
          liquid_task = "rocketchat-mongo"
        }
        port_map {
          mongo = 27017
        }
      }
      resources {
        memory = 500
        cpu = 400
        network {
          port "mongo" {}
        }
      }
      service {
        name = "rocketchat-mongo"
        port = "mongo"
        check {
          name = "rocketchat-mongo alive on tcp"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }
  }

  group "app" {
    ${ continuous_reschedule() }

    task "rocketchat" {
      driver = "docker"
      config = {
        image = "rocket.chat:1.1.1"
        args = ["node", "/local/main.js"]
        labels {
          liquid_task = "rocketchat-app"
        }
        port_map {
          web = 3000
        }
      }
      template {
        data = <<EOF
          {{- range service "rocketchat-mongo" }}
            MONGO_URL=mongodb://{{.Address}}:{{.Port}}/meteor
            MONGO_OPLOG_URL=mongodb://{{.Address}}:{{.Port}}/local?replSet=rs01
          {{- end }}
          ROOT_URL=${config.liquid_http_protocol}://rocketchat.${config.liquid_domain}
          {{- with secret "liquid/rocketchat/adminuser" }}
            ADMIN_USERNAME={{.Data.username}}
            ADMIN_PASS={{.Data.pass}}
          {{- end }}
          ADMIN_EMAIL=admin@example.com
          Organization_Name=Liquid
          Site_Name=Liquid
          OVERWRITE_SETTING_Show_Setup_Wizard=completed
          OVERWRITE_SETTING_registerServer=false
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid=true
          {{- range service "core" }}
            OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-token_path=http://{{.Address}}:{{.Port}}/o/token/
            OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-identity_path=http://{{.Address}}:{{.Port}}/accounts/profile
          {{- end }}
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-authorize_path=${config.liquid_http_protocol}://${liquid_domain}/o/authorize/
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-scope=read
          {{- with secret "liquid/rocketchat/auth.oauth2" }}
            OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-id={{.Data.client_id}}
            OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-secret={{.Data.client_secret}}
          {{- end }}
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-login_style=redirect
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-token_sent_via=header
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-button_label_text=Click here to get in!
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-merge_roles=true
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-merge_users=true
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-username_field=id
          OVERWRITE_SETTING_Accounts_OAuth_Custom-Liquid-roles_claim=roles
          OVERWRITE_SETTING_Accounts_AllowPasswordChange=false
          OVERWRITE_SETTING_Accounts_ForgetUserSessionOnWindowClose=true
          OVERWRITE_SETTING_Accounts_RegistrationForm=Disabled
        EOF
        destination = "local/liquid.env"
      }
      template {
        data = <<EOF
          var fs = require('fs');
          var dotenv = ('' + fs.readFileSync('/local/liquid.env')).trim();
          for (const a of dotenv.split(/\n/)) {
            [_,k,v]=a.trim().match(/^([^=]+)=(.*)/);
            process.env[k]=v;
          }
          require('/app/bundle/main.js');
        EOF
        destination = "local/main.js"
      }
      resources {
        memory = 800
        cpu = 400
        network {
          port "web" {}
        }
      }
      service {
        name = "rocketchat-app"
        port = "web"
        tags = [
          "traefik.enable=true",
          "traefik.frontend.rule=Host:rocketchat.${liquid_domain}",
        ]
        check {
          name = "rocketchat alive on http"
          initial_status = "critical"
          type = "http"
          path = "/"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
          header {
            Host = ["rocketchat.${liquid_domain}"]
          }
        }
      }
    }
  }

  ${- '' and authproxy_group(
      'rocketchat',
      host='rocketchat.' + liquid_domain,
      upstream='rocketchat-app',
    ) }
}
