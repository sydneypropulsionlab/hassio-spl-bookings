# SPL Equipment Booking

Equipment booking for the Sydney Propulsion Lab, using [LibreBooking](https://librebooking.readthedocs.io) (open source, GPL-3.0).

- Users register with their University email and book equipment by time slot.
- Equipment can require approval: a booking stays pending until an approver accepts it, and only approved bookings appear on the calendar.
- The schedule is public, so anyone can see it without logging in. It can be embedded in the SPL wiki.

## Before you install

Install and start the official **MariaDB** add-on: Settings > Add-ons > Add-on Store > MariaDB. Its default settings are fine. This add-on creates its own database and database user in it, and never touches other databases.

## Installing

Either:

- copy the `spl_librebooking` folder into Home Assistant's `addons` share (for example over the Samba share add-on), then go to Add-on Store, choose ⋮ > Check for updates, and find it under **Local add-ons**; or
- put this repository on GitHub and add its URL under Add-on Store > ⋮ > Repositories.

The first install builds the add-on on the Home Assistant machine, which takes a few minutes.

## First start

1. On the **Configuration** tab, set:
   - **Public address**: where people reach the site, without `/Web`. To start with, `http://homeassistant.local:8090` (or the HA IP address) is fine; change it when you give the site its own address, e.g. `https://booking.sydneypropulsionlab.org`.
   - **Administrator email**: your University address.
2. Start the add-on and watch the **Log** tab. On the first start it creates the `librebooking` database and installs LibreBooking. The log ends with "Starting LibreBooking".
3. Open the web UI, choose **Register**, and register with the administrator email. That account is the administrator.

Later starts apply any LibreBooking database upgrades automatically. If the database name already holds tables that aren't LibreBooking's, the add-on stops rather than change them.

## Setting up equipment and approvals

All in the site, under **Application Management**:

1. **Schedules**: the default schedule works. Set its time slots, e.g. 30-minute or 1-hour blocks during lab hours.
2. **Resources**: add each bookable item (e.g. "Windshaper (N107)", "Form 4 (S120)"). On each one:
   - **Access > Reservations must be approved**: on for equipment that needs approval.
   - **Access > Permission is automatically granted**: off if only some people may book it; then grant permission to a group (below).
   - **Resource administrator**: the group whose members approve bookings for it.
3. **Groups**: create groups such as "Windshaper approvers" (give the group the *Resource Admin* role) and "Windshaper users" (grant it permission on the resource).
4. **Users**: add people to groups once they register.

Approvers see pending bookings under **Application Management > Reservations** (filter by "Pending") and can approve or reject them. With **Email approvers** on and email set up, they're emailed when a booking is waiting.

LibreBooking doesn't know about SPL inductions. Approvers should check the person holds a current induction for the equipment before approving.

## Email

Set **SMTP server**, port, security, username and password. With no SMTP server, email is off and the site still works, but nobody is notified about approvals. **Send email from** defaults to the administrator email; use an address the SMTP server is allowed to send from.

## Showing the calendar in the wiki

The public pages are:

| Page | Address |
| --- | --- |
| Schedule (booked times per resource, by day) | `<public address>/Web/view-schedule.php` |
| Calendar (month or week view) | `<public address>/Web/view-calendar.php` |

With the wiki's iframe plugin:

```
{{url>https://booking.sydneypropulsionlab.org/Web/view-schedule.php 100%,800px}}

[[https://booking.sydneypropulsionlab.org/Web/|Book equipment]]
```

Log in and book on the booking site itself (the "Book equipment" link), not inside the iframe: browsers often block logins inside a frame from another site.

**Sites allowed to embed the booking pages**: add `https://wiki.sydneypropulsionlab.org`. Then only the wiki and the booking site itself can show the pages in a frame, which stops other sites framing the login page. With the list empty, no frame restriction is sent.

**Show booking details publicly** off (the default) shows the public booked times only. **Hide who booked** keeps names and contact details from other users.

People can also subscribe to calendars in Outlook or Google: in the site, **Schedule > Resource Calendar** or **My Account > My Calendar** has a subscription link.

## Options

| Option | What it does |
| --- | --- |
| Public address | Address of the site, used in emails and links |
| Administrator email | Registering with this address makes you the administrator |
| Site title, Organisation name, Organisation website | Shown in the header |
| Timezone | e.g. `Australia/Sydney` |
| Database name | The MariaDB database. Don't change it after the first start |
| Allow people to register | Off: only the administrator adds users |
| Allowed email domains | e.g. `sydney.edu.au,uni.sydney.edu.au`; empty allows any |
| Public schedule | Anyone can see the schedule without logging in |
| Show booking details publicly | Off: the public sees booked times only |
| Hide who booked | Hide names and contact details from other users |
| Days shown publicly | How far ahead the public schedule and calendar feeds go |
| Email approvers | Email admins when a booking needs approval |
| SMTP server, port, security, username, password, Send email from | Outgoing email |
| Sites allowed to embed the booking pages | Sites that may show the pages in an iframe |
| Log level | `none`, `error` or `debug` |
| Extra LibreBooking settings | Advanced: any [LibreBooking setting](https://librebooking.readthedocs.io/en/latest/BASIC-CONFIGURATION.html) as `LB_KEY=value` |

## Where things are kept

| What | Where | Backed up |
| --- | --- | --- |
| Bookings, users, resources | The `librebooking` database in the MariaDB add-on | With the MariaDB add-on |
| Uploaded images and attachments, generated passwords | The add-on's private `/data` | With this add-on |
| `config.php` and plugin settings | `addon_configs/<this add-on>/` (visible over Samba) | With this add-on |

Back up and restore this add-on and the MariaDB add-on together.

Settings from the Configuration tab override `config.php`. The database password is never written to `config.php`; the add-on passes it to LibreBooking directly.

## Updating LibreBooking

Change the image tag in the `Dockerfile` (e.g. `librebooking/librebooking:7.3.0`; check the [published tags](https://hub.docker.com/r/librebooking/librebooking/tags) first), bump `version` in `config.yaml`, and update the add-on. On start it applies LibreBooking's database upgrades. Back up both add-ons first.

## Troubleshooting

- **"The MariaDB add-on is not available"**: install and start the MariaDB add-on, then restart this one.
- **Links in emails go to the wrong address**: set Public address.
- **Blank iframe in the wiki**: add the wiki's address to *Sites allowed to embed*, or empty that list.
- **Can't register**: check *Allow people to register* and *Allowed email domains*.
