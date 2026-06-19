{ self }:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.shimmie;

  mkExtensionsConfig = exts:
    if exts == [] then null
    else ''
      <?php
      define("EXTRA_EXTS", "${lib.concatStringsSep "," exts}");
    '';

  mkShimmieConfig = ''
    <?php
    define('DATABASE_DSN', 'sqlite:${cfg.dbPath}');
    $secret = getenv('SHIMMIE_SECRET');
    if ($secret !== false) {
        define('SECRET', $secret);
    }
    ${lib.optionalString (cfg.settings.cacheDsn != null) "define('CACHE_DSN', '${cfg.settings.cacheDsn}');"}
    ${lib.optionalString (cfg.settings.warehouseSplits != 1) "define('WH_SPLITS', ${toString cfg.settings.warehouseSplits});"}
    ${lib.optionalString (cfg.settings.timezone != null) "define('TIMEZONE', '${cfg.settings.timezone}');"}
    ${lib.optionalString (cfg.settings.baseHref != null) "define('BASE_HREF', '${cfg.settings.baseHref}');"}
    ${lib.optionalString (cfg.settings.trustedProxies != []) "define('TRUSTED_PROXIES', [${lib.concatMapStrings (p: "'${p}',") cfg.settings.trustedProxies}]);"}
  '';

  seedSpec = if cfg.seedSql != []
    then pkgs.writeText "shimmie-seed-spec.json"
      (builtins.toJSON {
        dataDir = cfg.dataDir;
        entries = cfg.seedSql;
      })
    else "";
in
{
  options.services.shimmie = with lib; {
    enable = mkEnableOption "shimmie2, a taggable image board";

    user = mkOption {
      type = types.str;
      default = "shimmie";
      description = "Owner of runtime and data directories.";
    };

    group = mkOption {
      type = types.str;
      default = "shimmie";
      description = "Group for all created files.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/shimmie";
      description = "Runtime dir for shimmie source code and composer deps.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/srv/shimmie";
      description = "Persistent data dir for images and thumbnails.";
    };

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.default;
      defaultText = literalExpression "default flake package";
      description = "shimmie2 source package to deploy.";
    };

    phpPackage = mkOption {
      type = types.package;
      default = pkgs.php84.buildEnv {
        extensions = { enabled, all }: enabled ++ (with all; [
          pdo_sqlite
          gd
          mbstring
          fileinfo
          apcu
        ]);
        extraConfig = ''
          memory_limit = 256M
          post_max_size = 50M
          upload_max_filesize = 48M
        '';
      };
      description = "PHP package with required extensions.";
    };

    pool = mkOption {
      type = types.str;
      default = "shimmie";
      description = "Name of the php-fpm pool.";
    };

    port = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = ''
        Additional local HTTP port for LAN access. Added as an extra
        `listen` directive on the nginx server block (no HTTPS).
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the local firewall port.";
    };

    dbPath = mkOption {
      type = types.str;
      default = "/srv/shimmie/shimmie.db";
      example = "/srv/shimmie/shimmie.db";
      description = ''
        Absolute path to the SQLite db file (DATABASE_DSN = `sqlite:''${dbPath}`).
      '';
    };

    settings = {
      cacheDsn = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "apc://";
        description = ''
          `null` disables caching. `"apc://"` enables APCu in-process caching.
          `"memcached://host:port"` and `"redis://host:port"` are also supported.
        '';
      };

      warehouseSplits = mkOption {
        type = types.ints.between 1 3;
        default = 1;
        description = "Warehouse directory depth, set to 2 for millions of posts.";
      };

      timezone = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "UTC";
        description = "PHP timezone or `null` for the system default.";
      };

      baseHref = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/gallery";
        description = ''
          Path prefix when shimmie runs behind a reverse proxy at a sub-path
          e.g. `https://example.com/gallery/`.
        '';
      };

      trustedProxies = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"];
        description = ''
          CIDR ranges of trusted reverse proxies. Used to correctly determine the
          real client IP from `X-Forwarded-For`.
        '';
      };
    };

    extensions = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["approval" "auto_tagger" "autocomplete" "home" "pools"];
      description = "Extensions to be enabled (EXTRA_EXTS of extensions.conf.php).";
    };

    userClasses = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = ''
        Writes to user-classes.conf.php. Requires the `user_class_file` extension.
      '';
    };

    envFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path to an environment file, which must contain a `SHIMMIE_SECRET=...` k/v.
        All environment variables set are available to shimmie. SHIMMIE_SECRET is
        read from the environment at runtime and used as the value of SECRET by the
        generated shimmie.conf.php.
      '';
    };

    seedSql = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Stable key used for determining whether a oneshot handler should run
              again. If not set, a content hash of the full entry is used. Setting a
              name lets you replace the SQL content without re-executing the change.
            '';
          };
          requires = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Tables that must exist before this SQL runs.";
          };
          sql = mkOption {
            type = types.lines;
            description = "SQL to execute after all required tables exist.";
          };
          oneshot = mkOption {
            type = types.bool;
            default = false;
            description = ''
              If true, execute only once per unique SQL content (tracked via a
              marker file). If false (default), execute on every service restart.
            '';
          };
        };
      });
      default = [];
      example = lib.literalExpression ''
        [{
          name = "tag-categories";
          requires = ["image_tag_categories"];
          oneshot = true;
          sql = '''
            DELETE FROM image_tag_categories;
            INSERT INTO image_tag_categories VALUES
              ('artist', 'Artist', 'Artists', '#BB6666'),
              ('series', 'Series', 'Series', '#6666BB');
          ''';
        }]
      '';
      description = ''
        Ordered list of seed specs. Each entry executes its `sql`, but only if all
        tables in `requires` exist. Use `oneshot` for initial data that shouldn't
        override GUI-side changes (e.g. config, tag categories, default users).
      '';
    };

    nginx = {
      enable = mkEnableOption "nginx virtual host for shimmie2";

      virtualHost = mkOption {
        type = types.str;
        example = "img.example.com";
        description = "FQDN for the nginx server block.";
      };

      forceSSL = mkOption {
        type = types.bool;
        default = true;
        description = "Redirect HTTP to HTTPS.";
      };

      useACMEHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example.com";
        description = "ACME host to use for TLS certificate.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # write configs to /etc
    (let
      mkConfig = name: text: lib.mkIf (text != null) {
        environment.etc."shimmie/${name}" = {
          inherit text;
          mode = "0444";
        };
      };
    in lib.mkMerge [
      (mkConfig "shimmie.conf.php" mkShimmieConfig)
      (mkConfig "extensions.conf.php" (mkExtensionsConfig cfg.extensions))
      (mkConfig "user-classes.conf.php" cfg.userClasses)
    ])

    (lib.mkIf (cfg.openFirewall && cfg.port != null) {
      networking.firewall.allowedTCPPorts = [ cfg.port ];
    })

    {
      # {{{ user/group/dir setup
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
      };
      users.groups.${cfg.group} = {
        members = lib.optional cfg.nginx.enable "nginx";
      };

      systemd.tmpfiles.settings."10-shimmie" = {
        "${cfg.stateDir}".d = {
          user = cfg.user;
          group = cfg.group;
          mode = "0750";
        };
        "${cfg.dataDir}".d = {
          user = cfg.user;
          group = cfg.group;
          mode = "0770";
        };
      };
      # }}}

      # {{{ init service
      systemd.services.shimmie-init = {
        description = "Initialize shimmie2 runtime";
        wantedBy = [ "multi-user.target" ];
        before = [ "phpfpm-${cfg.pool}.service" ];
        requires = [ "local-fs.target" ];
        after = [ "local-fs.target" ];
        partOf = [ "phpfpm-${cfg.pool}.service" ];
        path = [ cfg.phpPackage ];
        restartTriggers = [
          (builtins.hashString "sha256" (builtins.toJSON {
            inherit (cfg) extensions seedSql settings userClasses dbPath dataDir stateDir;
          }))
        ];

        script = ''
          set -eux

          stamp="${cfg.stateDir}/.shimmie_pkg"
          if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "${cfg.package}" ]; then
            echo "==> package unchanged, skipping installation"
          else
            echo "==> installing shimmie2 source to ${cfg.stateDir}"
            mkdir -p "${cfg.stateDir}"
            for item in "${cfg.package}/share/shimmie2/"*; do
              b=$(basename "$item")
              if [ "$b" = data ] || [ "$b" = vendor ]; then continue; fi
              rm -rf "${cfg.stateDir}/$b"
              cp -r --no-preserve=mode "$item" "${cfg.stateDir}/$b"
            done

            echo "==> installing php dependencies via composer"
            cd "${cfg.stateDir}"
            ${cfg.phpPackage.packages.composer}/bin/composer install \
              --no-dev --no-interaction --optimize-autoloader --no-progress

            echo "==> linking data directory"
            ln -sfn "${cfg.dataDir}" "${cfg.stateDir}/data"

            echo "==> linking nix-managed config files"
            mkdir -p "${cfg.dataDir}/config"
            for name in shimmie extensions user-classes; do
              src="/etc/shimmie/$name.conf.php"
              dst="${cfg.dataDir}/config/$name.conf.php"
              if [ -f "$src" ]; then
                rm -f "$dst"
                ln -sfn "$src" "$dst"
              else
                rm -f "$dst"
              fi
            done

            echo "==> bootstrapping core database tables"
            ${cfg.phpPackage}/bin/php ${./install_db.php}

            echo "${cfg.package}" > "$stamp"
          fi

          cd "${cfg.stateDir}"

          echo "==> running database upgrade for extensions"
          ${cfg.phpPackage}/bin/php ${./upgrade_db.php}

          ${lib.optionalString (cfg.seedSql != []) ''
            echo "==> applying declarative sql initialization"
            ${cfg.phpPackage}/bin/php ${./apply_seeds.php} ${seedSpec}
          ''}

          echo "==> fixing ownership"
          chown -R ${cfg.user}:${cfg.group} "${cfg.stateDir}"
          chown -R ${cfg.user}:${cfg.group} "${cfg.dataDir}"
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;
          Environment = [ "COMPOSER_HOME=${cfg.stateDir}/.composer" ];
          PrivateTmp = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ cfg.stateDir cfg.dataDir ];
          UMask = "0027";
        };
      };
      # }}}

      # {{{ php-fpm
      services.phpfpm.pools.${cfg.pool} = {
        inherit (cfg) user group;
        phpPackage = cfg.phpPackage;

				# TODO: make more of these configurable?
        settings = {
          "listen.owner" = cfg.user;
          "listen.group" = if cfg.nginx.enable then "nginx" else cfg.group;
          "listen.mode" = "0660";
          "chdir" = cfg.stateDir;
          "pm" = "dynamic";
          "pm.max_children" = 10;
          "pm.min_spare_servers" = 2;
          "pm.max_spare_servers" = 4;
          "pm.max_requests" = 500;
        };
      };

      systemd.services."phpfpm-${cfg.pool}" = {
        # when restarting this unit, stop self, restart shimmie-init, start self
        bindsTo = [ "shimmie-init.service" ];
        after = [ "shimmie-init.service" ];
        restartTriggers = [
          (builtins.hashString "sha256" (builtins.toJSON {
            inherit (cfg) extensions seedSql settings userClasses dbPath dataDir;
          }))
        ];
        serviceConfig = lib.mkIf (cfg.envFile != null) {
          EnvironmentFile = cfg.envFile;
        };
      };
      # }}}
    }

    # {{{ nginx
    (lib.mkIf cfg.nginx.enable {
      systemd.services.nginx.serviceConfig.ReadOnlyPaths = [ cfg.stateDir cfg.dataDir ];
      services.nginx.virtualHosts."${cfg.nginx.virtualHost}" = {
        forceSSL = cfg.nginx.forceSSL;
        useACMEHost = lib.mkIf (cfg.nginx.useACMEHost != null) cfg.nginx.useACMEHost;
        root = cfg.stateDir;

        extraConfig = lib.mkIf (cfg.port != null) "listen ${toString cfg.port};";

        locations = {
          # warehouse images from disk
          "~ \"^/_images/([0-9a-f]{2})([0-9a-f]{30}).*$\"" = {
            priority = 10;
            alias = "${cfg.dataDir}/images/$1/$1$2";
            extraConfig = "expires 30d;";
          };

          # warehouse thumbs from disk
          "~ \"^/_thumbs/([0-9a-f]{2})([0-9a-f]{30}).*$\"" = {
            priority = 20;
            alias = "${cfg.dataDir}/thumbs/$1/$1$2";
            extraConfig = "expires 30d;";
          };

          # static assets, serve from disk if they exist, else fall through to /
          "~ \"^.*\\.(css|js|map|gif|png|jpg|jpeg|ico)$\"" = {
            priority = 30;
            tryFiles = "$uri /";
            extraConfig = "expires 1d;";
          };

          # everything else goes to php-fpm
          "/" = {
            priority = 100;
            extraConfig = ''
              include ${config.services.nginx.package}/conf/fastcgi_params;
              fastcgi_param SCRIPT_FILENAME $document_root/index.php;
              fastcgi_pass unix:/run/phpfpm/${cfg.pool}.sock;
              fastcgi_read_timeout 300;
            '';
          };
        };
      };
    })
    # }}}
  ]);
}
