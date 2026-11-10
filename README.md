# SPL Booking add-on

Equipment booking with approvals and a public calendar for the Sydney Propulsion Lab: [LibreBooking](https://librebooking.readthedocs.io) packaged as a Home Assistant add-on.

| Path | What it is |
| --- | --- |
| `spl_librebooking/` | The add-on. `DOCS.md` there covers installing and setting it up |
| `repository.yaml` | Makes this folder a Home Assistant add-on repository (for when it moves to GitHub) |
| `docker-compose.yml` | Runs the add-on with its own MariaDB on a laptop for testing |
| `local-test/options.example.json` | Add-on options for the laptop test |

## Testing on a laptop (Docker Desktop)

```
copy local-test\options.example.json local-test\options.json
docker compose up --build
```

Open http://localhost:8090/Web/ and register with the `admin_email` in `options.json`. Delete `local-data` to start again.

## How it works

The add-on is LibreBooking's official image (`librebooking/librebooking`) with a start-up script, `spl_librebooking/rootfs/opt/spl/run.sh`, that:

1. reads the add-on options;
2. gets the MariaDB add-on's login from the Supervisor and creates this add-on's database and user (never dropping anything);
3. installs LibreBooking into an empty database, or applies database upgrades, using LibreBooking's own installer (`lb-db.php`);
4. keeps uploads in `/data` and `config.php` in the add-on config folder;
5. starts LibreBooking's background jobs and Apache.

Settings are passed to LibreBooking as `LB_...` environment variables, which take precedence over `config.php`.
