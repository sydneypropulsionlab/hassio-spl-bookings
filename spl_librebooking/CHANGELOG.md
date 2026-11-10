# Changelog

## 0.1.4 — 2026-11-09

- New options Database login and Database password: use a login created in the MariaDB add-on's own configuration instead of the Supervisor's service login. Use this if the service login is refused.

## 0.1.3 — 2026-11-09

- Log in to the MariaDB add-on over IPv4. `core-mariadb` resolved to an IPv6 address, and the MariaDB add-on only allows its service login from IPv4 addresses ("Access denied for user 'service'@'fd0c:...'").

## 0.1.2 — 2026-11-09

- Connect to the MariaDB add-on without TLS. The MariaDB client in LibreBooking 7.2.0's image verifies TLS certificates by default and refused the connection ("cannot log in to MariaDB").
- Show the actual MariaDB error while waiting and when giving up.

## 0.1.1 — 2026-11-09

- Build from LibreBooking 7.2.0, the current release. There is no published 4.3.0 image, so 0.1.0 failed to build.

## 0.1.0 — 2026-11-06

- First version (did not build: it named an image tag that was never published).
- Uses the MariaDB add-on; creates its own database and user, installs LibreBooking on the first start and applies its database upgrades on later starts. Never drops a database or installs over existing tables.
- Options for the public address, administrator email, allowed email domains, public schedule and privacy, approval emails, SMTP, and the sites allowed to embed the pages (for the SPL wiki).
- Uploads and generated passwords kept in `/data`; `config.php` in the add-on config folder. Database and install passwords are passed to LibreBooking as environment variables and never written to `config.php` or the log.
- Runs LibreBooking's background jobs (reminders, auto-release, waitlist, session clean-up).
