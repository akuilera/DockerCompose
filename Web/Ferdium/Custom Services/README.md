# Custom Services (recipes) for ferdium-server

This guide explains how to create, upload and maintain **custom services** ("recipes") for the self-hosted [ferdium-server](https://github.com/ferdium/ferdium-server) in this stack. Everything below applies to this exact deployment where ferdium-server runs in Docker and the Ferdium desktop client connects to it as a custom server.

Read it together with `../README.md` (the stack's own manual) and the upstream documentation linked at the bottom.

## What a recipe is (and what it is not)

A Ferdium recipe is a tiny **node module** plus a **URL**. Ferdium loads that URL into an Electron webview and the recipe tells Ferdium how to display it: unread badges, the active chat title, dark mode and custom styles. That is the whole model — a recipe is **not** a native app, it is a web page and some JavaScript around it.

Two consequences follow:

- Every recipe needs a service that has an HTTP (web) version. If a service is truly Android-only and has no web interface at all, it cannot be made into a recipe (see [Android-only / mobile-only services](#android-only--mobile-only-services)).
- A recipe never hosts or stores your conversations. The account, its services and the recipes themselves live on your ferdium-server; the messages keep living inside each web service.

## Where a recipe lives in this stack

Three copies matter:

1. **Source** — the files you author on your device, split into two folders (see [Public vs Private recipes](#public-vs-private-recipes)): `Public/` holds the recipes that are safe to publicize (no personal URLs) and is versioned in git; recipes whose `serviceURL`/icon URL reveals personal data belong in the local, gitignored `Private/` folder next to this guide. This device copy is your source of truth.
2. **Runtime (server)** — ferdium-server packages the recipe into a proper node module and stores it in the recipes volume mounted from the host: `${PATH_TO_CONTAINERS}/Ferdium/recipes:/app/build/recipes` (see `../docker-compose.yml`). You **do not hand-edit files inside that volume**; recipes are delivered through the web UI (see [Uploading a recipe to your server](#uploading-a-recipe-to-your-server)).
3. **Cache (client)** — the desktop client downloads the recipe from your server and keeps a copy in its local `recipes` folder.

Because the server compiles whatever you upload, the **source of truth is always your local copy on the device**, not the files sitting on the server.

## When do you need a recipe at all?

Ferdium already ships a built-in **Custom Website** service: it lets you add any URL with your own name and icon, no recipe involved. Use it for a plain web page you just want in the sidebar.

Write a recipe when you want any of: an unread badge, the active-chat title, dark-mode handling, team/custom URL semantics, or a fixed, nicely named entry in the service store (`ferdium:custom`). Recipes are also the only way to add services that want a mobile user agent (see below).

## Recipe structure (files)

Every recipe lives in its own folder. The three files marked *mandatory* are the minimum that will be accepted; the rest are optional but show up in almost every real recipe.

| File | Mandatory | Purpose |
| --- | --- | --- |
| `package.json` | yes | Recipe metadata and integration config. |
| `index.js` | yes | Backend script. It runs inside Ferdium itself, **not** in the service webview. |
| `icon.svg` | yes* | Default icon for the service (square SVG). Only skipped if `defaultIcon` is set in `package.json`. |
| `webview.js` | no | Frontend script injected into the service page. Where badge/title logic goes. |
| `darkmode.css` | no | Custom dark theme, applied when dark mode is enabled. |

Other CSS/JS files referenced from `webview.js` (e.g. `service.css`) are allowed too.

The folder name must match the recipe `id` (official recipes do this), but for a custom recipe uploaded to your server the **Service ID** you type on the upload page is what identifies it.

## `package.json`

Standard node-module metadata with a mandatory `config` block. The fields `id`, `name`, `version` and `config` are **mandatory**; `version` must be valid semver.

```json
{
  "id": "<service-id>",
  "name": "<Service Name>",
  "version": "1.0.0",
  "license": "MIT",
  "repository": "https://example.com/<account>/<service>-recipe",
  "config": {
    "serviceURL": "https://www.example.com/",
    "hasNotificationSound": true
  }
}
```

### Top-level fields

| Field | Meaning |
| --- | --- |
| `id` | Unique identifier. No spaces or special characters (e.g. `google-drive`). Mandatory. |
| `name` | Display name, may contain spaces and unicode. Mandatory. |
| `version` | Semver. Used to decide whether clients receive a recipe update — **always bump it when you change the recipe**. Mandatory. |
| `config` | Ferdium integration config (below). Mandatory. |
| `license` | SPDX identifier, MIT preferred. |
| `repository` | Public URL where the recipe source lives. |
| `aliases` | Alternate names to find the recipe. |
| `defaultIcon` | URL of the default icon. If present, `icon.svg` is not required. |

### `config` flags (all optional unless noted)

| Flag | Default | Meaning |
| --- | --- | --- |
| `serviceURL` | — | URL loaded into the webview. Supports `{teamId}` placeholders (e.g. `https://{teamId}.slack.com`). Leave empty for services that accept custom URLs. |
| `hasTeamId` | `false` | The service is team-based (Slack-style); the add-service form asks for a team id. |
| `urlInputPrefix` / `urlInputSuffix` | — | Shown around the team-id input when `hasTeamId` is true. |
| `hasHostedOption` | `false` | Service can be hosted on-premise and therefore has team id / custom URL handling. |
| `hasCustomUrl` | `false` | Service supports custom URLs (Mattermost-style); the add-service form asks for a URL. |
| `hasNotificationSound` | `false` | The service plays its own notification sound; prevents double sounds. |
| `hasDirectMessages` | `true` | Whether the user can enable direct-message badges (mentions of you). |
| `hasIndirectMessages` | `false` | Whether the user can enable indirect-message badges (mentions in general channels). |
| `message` | — | Info text shown in the add/edit service screen. |
| `disablewebsecurity` | `false` | Disables web security in the webview (some services need it). |
| `allowFavoritesDelineationInUnreadCount` | `false` | Lets the user exclude non-favorite folders from unread counts (Outlook-style). |

## `index.js`

The backend of the recipe. For a simple, static-URL service this is the entire file:

```js
module.exports = Ferdium => Ferdium;
```

### Forcing a different user agent

Ferdium suffixes its own signature to the browser user agent, and some services reject or misbehave because of it. Strip it, or return a completely different agent (this is how you target mobile-only sites — see [Android-only / mobile-only services](#android-only--mobile-only-services)):

```js
// Rename the class to your service (e.g. "MyMessenger") when copying.
module.exports = Ferdium =>
  class CustomService extends Ferdium {
    overrideUserAgent() {
      return window.navigator.userAgent.replace(
        /(Ferdium|Electron)\/\S+ \([^)]+\)/g,
        '',
      );
    }
  };
```

Returning a fixed string replaces the agent entirely, e.g. `return 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';`.

### Validating custom URLs

For services that can be self-hosted, validate the URL the user typed so the webview refuses to open a wrong server (e.g. `google.com`). The method must return a `Promise`:

```js
// Rename the class to your service (e.g. "MyMessenger") when copying.
module.exports = Ferdium =>
  class CustomService extends Ferdium {
    async validateUrl(url) {
      try {
        const resp = await window.fetch(`${url}/api/info`, {
          method: 'GET',
          headers: { 'Content-Type': 'application/json' },
        });
        const data = await resp.json();
        return Object.prototype.hasOwnProperty.call(data, 'version');
      } catch (err) {
        console.error(err);
        return false;
      }
    }
  };
```

## `webview.js`

The frontend script. It runs inside the service page and speaks to Ferdium through the `Ferdium` object. Common helpers:

- `Ferdium.setBadge(direct, indirect)` — set the unread badge counts.
- `Ferdium.setDialogTitle(title)` — set the active chat/person name.
- `Ferdium.injectCSS(path...)` — inject local CSS files into the page.
- `Ferdium.injectJSUnsafe(file...)` — inject a JS file without context isolation (needed to touch the page's `window`).
- `Ferdium.loop(fn)` — run `fn` every ~1s (badge polling).
- `Ferdium.onNotify(fn)` — intercept/tweak the service's notifications.
- `Ferdium.handleDarkMode(callback)` — custom dark-mode toggle instead of `darkmode.css`.
- `Ferdium.clearStorageData(id, {...})` / `Ferdium.releaseServiceWorkers()` — cleanup helpers.
- `Ferdium.safeParseInt(text)` — safely parse a DOM text node into an int.
- `Ferdium.isImage(url)` — check if a URL points at an image.

A badge-polling recipe looks like this (pattern from the official Telegram recipe):

```js
module.exports = Ferdium => {
  const getMessages = () => {
    let direct = 0;
    let indirect = 0;
    const elements = document.querySelectorAll('.list-item');
    for (const element of elements) {
      const badge = element.querySelector('.badge');
      if (badge) {
        const value = Ferdium.safeParseInt(badge.textContent);
        direct += value;
      }
    }
    Ferdium.setBadge(direct, indirect);
  };

  const getActiveDialogTitle = () => {
    Ferdium.setDialogTitle(document.title);
  };

  Ferdium.loop(getMessages);
  Ferdium.loop(getActiveDialogTitle);
};
```

Selectors are always site-specific: open the service's developer tools (see [Debugging](#debugging)) and adapt the example to the actual page.

## `darkmode.css`

Drop a `darkmode.css` in the recipe folder to ship your own dark theme. Once the file exists, the user can enable **Dark Mode** in the service settings. Some services fight style overrides (e.g. Google Calendar); for those, or when the service has its own dark switch (Reddit, YouTube), use `handleDarkMode` in `webview.js` instead.

## Icons

The icon must be a **square SVG** (the official guide asks for 1024×1024). On the upload page you provide it twice, in two different roles:

- **`icon.svg`** — inside the recipe files you upload; this becomes the default icon shown in the client sidebar. This repository uses the **official service logo** on a **transparent background** (downloaded from Simple Icons, dashboard-icons or the project's own repo); no personal colours.
- **A public URL to the same SVG** — shown as the store logo. The field is **mandatory** (the server validates it as a real URL) but only drives the store listing; the sidebar icon comes from `icon.svg`. Since this repository is hosted on the user's own Forgejo (not GitHub), jsDelivr cannot serve it — paste the **Forgejo raw URL** of the recipe's `icon.svg` instead. That URL is stored only in the server database; it is never written into the recipe files or into this repository (see [Public vs Private recipes](#public-vs-private-recipes)).

## Public vs Private recipes

Recipes are split into two folders next to this guide:

| Folder | Content | Committed? |
| --- | --- | --- |
| **`Public/`** | Recipes with **no personal data**: `serviceURL` empty + `hasCustomUrl: true`, generic names, official logos. They are ready to push. |
| **`Private/`** | Recipes whose URL, name or icon would reveal personal data. Gitignored (root rule `**/Ferdium/Custom Services/Private/`), never committed, never reaches the server working copy. Deploy is always via `/new`, so that is fine. |

**`Public/` recipes** (self-hosted services, typed URL on add):

- `forgejo` — Forgejo (identical in behaviour to the official Gitea recipe; only name/icon differ)
- `borg-ui` — Borg-UI backup dashboard
- `n8n` — automation workflows
- `nginx-proxy-manager` — reverse proxy admin
- `syncthing` — file sync (one recipe, add it twice: server + client, two different URLs)
- `findmydevice` — FindMyDevice (FMD) remote device control
- `goaccess` — web log analyser
- `filebrowser` — file manager
- `grafana` — dashboards
- `cloudflare` — Cloudflare dashboard (fixed `serviceURL`, no custom URL)
- `applygator` — Applygator

**`Private/` recipes** (not listed here on purpose — see `Private/` on the device for what lives there; deploy them from that folder via `/new`).

You can add any of these recipes **more than once**, and each add becomes a fully independent Ferdium service with its own sandbox/session:
- **Syncthing** — one recipe entry per device or server the user owns (e.g. the server UI plus each client's local UI). This is why it shipped with `hasCustomUrl`: add it N times, one different URL each time.
- **FindMyDevice (FMD)** — the deployment URL may be the same for all instances; since every added service gets its own isolated webview partition and login session, you get one independent account each. Add the recipe once per account.

## Uploading a recipe to your server

Prerequisite: `IS_CREATION_ENABLED=true` in `../docker-compose.yml` (it already is in this stack). If it was toggled off, the upload page is disabled.

1. Go to `https://<domain>/new` in a browser and log in with your account.
2. Fill the form:

   | Field | Value |
   | --- | --- |
   | **Author** | Your name/handle. |
   | **Name** | Display name of the service (spaces and unicode allowed). |
   | **Service ID** | Unique id, no spaces/special chars (e.g. `my-messenger`). |
   | **Link to SVG image** | Public URL of the square 1024×1024 SVG logo (use jsDelivr for GitHub-hosted files). |
   | **Recipe files** | The raw files (`package.json`, `index.js`, `icon.svg`, plus any `webview.js`/`darkmode.css`). Drag & drop the **individual files** — do **not** upload a folder or a pre-packaged zip; the server packages the recipe itself. |

3. Submit. The server compiles the recipe into `/app/build/recipes` (your `${PATH_TO_CONTAINERS}/Ferdium/recipes` volume).
4. In the Ferdium client, add a new service and search for **`ferdium:custom`** — your recipe shows up there, pick it and log in.

## Android-only / mobile-only services

The one question that always comes up: "can I add a service that only has an Android app?". The rule of thumb:

- The recipe loads a **URL**. If the service has no HTTP interface at all, it cannot be a recipe — that is a hard no.
- If the service's web version is mobile-only, or its normal web page refuses non-mobile browsers, it often still works: point `serviceURL` at the mobile web URL and make the webview present itself as an Android device with `overrideUserAgent()` in `index.js`. Many services serve their mobile site (or a PWA) to such a client. This is what the [mobile-web example](examples/mobile-web/index.js) does.
- A **PWA** (installable web app) is the best-case scenario: it is a web app by design and usually works cleanly.

Limits to expect:

- **Notifications** come from the web page through the browser Notifications API; if the Android app pushes through native channels only, unread badges may not appear and you may need the polling approach in `webview.js`.
- **No native features.** The recipe is a browser tab; anything that requires the mobile OS or an installed app (some logins, FIDO keys beyond what the app already allows, camera/scanner flows) won't work.
- **Anti-bot risk.** Spoofing a mobile user agent on a service that expects a real mobile browser can get the account flagged or throttled. Use this only for services that genuinely welcome web/mobile-web traffic.

## Updating an existing recipe

Edit the source, **bump `version` in `package.json`** (semver), and upload the new files via `/new` again the same way. Ferdium uses the version number to decide whether a client should download the update — if you forget to bump it, nobody gets the new recipe.

## Debugging

- In the client, open **`Cmd/Ctrl+Alt+Shift+I`** to open the recipe's developer tools (the webview inspector). Use it to inspect the page and find the selectors for your badges/titles.
- Watch `docker compose logs -f ferdium-server` in `../` for errors during upload/packaging.

## Troubleshooting

Real issues hit with these recipes (this stack), with the fixes that worked.

### Google sign-in opens my external browser instead of logging in

Google's sign-in buttons use `target="_blank"` / `window.open()`, and Ferdium routes those out of the webview into the OS browser by design — it is not a recipe bug. Options, in order of convenience:

1. **Right-click the sign-in link/button → "Open link in Ferdium"** (or "Open link in this window"). This is the quickest reliable workaround.
2. Put the Google-based service in a **shared sandbox with another Google service** you already use (e.g. Google Calendar) so the session cookie is reused and the button isn't needed again.
3. While logging in, switch the service's **User-Agent override** to a current desktop Chrome, then remove the override once signed in.

### Service page reports "Loading CSS/JS chunk … failed" (e.g. Forgejo `dashboard-repo-list`, `activity-heatmap`)

The HTML was cached before the app re-built, so it still points at old hashed asset URLs that no longer exist, or the reverse proxy is failing to buffer downloads. Fixes:

- In the client: hard reload **`Ctrl+Shift+R`** (or right-click the service → Settings → **Clear Cache** — either clears the stale cached index).
- On the server/reverse proxy: make sure nginx can write its cache dir (`/var/cache/nginx/proxy_temp`) and consider not caching the service's `index.html`. If you cache assets, keys must include the new filenames.

### Grafana stuck on the "Loading Grafana" splash

Same failure class as the chunk errors above: the dashboard boots its frontend from `public/build` and the preloader never resolves when that bundle fails to load (stale cached HTML, proxy buffering, or an unusually slow first load). The recipe is an identity webview — there is nothing client-side to fix in it. Fixes:

- Hard reload **`Ctrl+Shift+R`** or right-click → Settings → **Clear Cache**; if it loaded after that, it was a stale-cache issue.
- On the server: stop nginx from caching Grafana's `index.html`, keep `proxy_temp` writable, and check `root_url` / `serve_from_sub_path` in `grafana.ini` if Grafana is served under a subpath.

### Adding the same service multiple times for different accounts

Ferdium isolates every added service in its own sandbox (its own `persist:service-*` session partition), so the same recipe can be added several times and each instance keeps a separate login. Use this for multi-account setups (e.g. several FMD accounts on the same URL) and multi-device setups (Syncthing once per device). Give each instance a distinct name/icon when adding so the sidebar stays readable.

### Multi-instance best practice: sessions are per instance, not per service type

Each added service carries its own isolated partition — that is why adding the same recipe twice works with two different logins. It also means a service you consider "single" scales to N instances with no recipe change; only the client-side add gets repeated.

### Web page is wider than the window

Ferdium's sidebar leaves the webview narrower than a normal browser tab, so a layout that fits a full browser window overflows here. Not a recipe bug — close the service's own sidebar if it has one, close the Ferdium sidebar, or zoom out with **`Ctrl+-`**.

## Repository hygiene (rules of this repo)

This folder is part of a **public template repository**. Recipes whose `serviceURL` or icon URL would reveal personal data (real domains, public IPs, usernames) must **never** be committed. The examples in `examples/` use `example.com` and generic ids on purpose — copy the structure and keep private values local.

**`Private/`** is the home for exactly those recipes: it lives next to this guide on the device, is excluded by the repo's root `.gitignore` (rule `**/Ferdium/Custom Services/Private/`), and therefore is never committed, pushed or pulled — it never reaches the server working copy, which is fine because deploy is always via the `/new` upload page. Keep each recipe in its own subfolder there (`Private/<service-id>/` with `package.json`, `index.js` and `icon.svg`, plus optional `webview.js` / `darkmode.css`) and upload the files you ship from that folder. Treat `Private/` as disposable: anything important should still be mirrored somewhere backed up, since it is not in git.

## References

- [Ferdium recipe integration guide](https://github.com/ferdium/ferdium-recipes/blob/main/docs/integration.md)
- [Integration config (package.json flags)](https://github.com/ferdium/ferdium-recipes/blob/main/docs/configuration.md)
- [Frontend API (webview.js)](https://github.com/ferdium/ferdium-recipes/blob/main/docs/frontend_api.md)
- [Updating recipes](https://github.com/ferdium/ferdium-recipes/blob/main/docs/updating.md)
- [ferdium-server](https://github.com/ferdium/ferdium-server)