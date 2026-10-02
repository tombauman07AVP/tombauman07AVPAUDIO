# Royal Pines Ballroom Audio

The interactive system map for the RACV Royal Pines ballroom: signal flow, patching, speakers, RF and the upgrade log. Staff sign-in is required.

The page you see on GitHub has **no venue information in it**. Everything lives in a private Supabase database. People have to sign in, and an admin has to give them access, before anything shows.

## What's in this repository

| File | What it is |
|---|---|
| `index.html` | The site. Replace this file whenever Claude sends you a new version. |
| `config.js` | Connects the site to your Supabase project. Set it once, then leave it alone. |
| `setup.sql` | The one-off database setup. You run it in Supabase, and it's kept here for reference. |
| `.github/workflows/keepalive.yml` | Optional. Stops the free database from going to sleep. |

## Roles

- **No access**: signed in, but sees nothing. Every new account starts here.
- **Viewer**: can use the whole site.
- **Editor**: can also edit and save.
- **Admin**: can also see the Admin page (activity log, people, versions) and undo changes.

The first account ever created becomes the admin automatically.

## Day to day

- **Add someone.** In Supabase, go to **Authentication → Users → Add user → Create new user**. Enter their email and a starting password, and tick **Auto Confirm User**. Then, in the site, go to **Admin → People** and give them a role. Tell them their password in person. They can change it by clicking their initials at the top right.
- **Forgotten password.** An admin opens **Admin → People** and uses **Set password** for that person.
- **Remove someone.** Set their role to **No access**, or delete them in Supabase under Authentication → Users.
- **See who did what.** Go to **Admin → Activity**. It records sign-ins, sign-outs, pages opened, searches, edits (with a list of exactly what changed), restores, and role and password changes. You can filter it, or download it as a CSV.
- **Undo a change.** Go to **Admin → Versions**, then click **Restore** twice. The old version comes back as the newest one, so nothing is lost.
- **Back up, or make a big update.** Go to **Admin → Backup**. **Download data** saves everything as one file. **Import a file** shows exactly what will change before you confirm, then saves it as a new version that you can undo from Versions.

## Updating the site

Upload the new `index.html` over the old one with **Add file → Upload files**. Leave `config.js` as it is. The content stays in the database, so updating the page never loses anything.

## Notes

- The free Supabase plan pauses a project after 7 days without use. The keep-awake job checks in every 3 days. If the project does pause, an admin can restore it from the Supabase dashboard.
- The values in `config.js` are meant to be public. Never put the **secret key** or the **database password** in this repository.
- Anyone who signs in is told that their activity is recorded.
