# Texas Land Law, PLLC website

A one-page site for Texas Land Law, PLLC, a real estate law firm in McAllen, Texas.

**This is a draft for the firm's review.** The page carries a review banner, is set not to be indexed by search engines, and its contact form is not connected. See [Before launch](#before-launch).

Preview: <http://johnw860.sg-host.com/>

## What is here

| Path | What it is |
| --- | --- |
| `public/index.html` | The whole site in one file: markup, styles, script and embedded fonts. |
| `scripts/deploy-sftp.sh` | Uploads `public/` to SiteGround over SFTP. |
| `.github/workflows/deploy.yml` | Runs the upload on every push to `main`. |

## Editing the site

Open `public/index.html` and scroll to the `SITE` settings block near the bottom. It holds the phone, email, street address, hours, form endpoint, logo file and attorney photo. Leave a value as `""` and the page leaves that item out. Everything else is ordinary HTML and CSS in the same file.

## Deploying

Every push to `main` uploads `public/` to the SiteGround site `johnw860.sg-host.com`. You can also run it by hand from the **Actions** tab (Deploy to SiteGround, then Run workflow).

The upload only adds and replaces files. It never deletes anything on the server.

### Secrets

Add these under **Settings > Secrets and variables > Actions**:

| Secret | Value |
| --- | --- |
| `SFTP_USER` | The SFTP username SiteGround shows for the key. |
| `SFTP_KEY` | The private key: the whole text, from the `-----BEGIN` line to the `-----END` line. |
| `SFTP_KEY_PASSPHRASE` | The password you set when you created the key. Leave it out if the key has none. |

For a SiteGround Multisite SFTP key, all three are in the Client Area: your profile menu, then **Multisite SFTP Access**, then the key's menu (**SFTP credentials** and **Private Key**). Under **Manage Websites** in the same menu, make sure this site is ticked.

The host (`sftp.siteground.net`), port (`18765`) and domain are plain values at the top of `.github/workflows/deploy.yml`.

### Optional variables

| Variable | Use |
| --- | --- |
| `SFTP_REMOTE_DIR` | The path to the site's `public_html`, if the script does not find it. It tries `<domain>/<domain>/public_html`, then `www/<domain>/public_html`, then `<domain>/public_html`. |
| `SFTP_KNOWN_HOSTS` | `known_hosts` line(s) for the server. Without it, the script trusts the host key it sees on each run. |

### Deploying from your own machine

```sh
SITE_DOMAIN=johnw860.sg-host.com \
SFTP_USER=your-sftp-user \
SFTP_KEY_FILE=~/.ssh/siteground \
bash scripts/deploy-sftp.sh
```

Add `DRY_RUN=1` to see what would be uploaded without uploading it. If the key has a password, pass it as `SFTP_KEY_PASSPHRASE`.

## Before launch

1. Fill in the `SITE` settings in `public/index.html`: phone, email, street address, hours and a form endpoint.
2. Have the attorney approve every line of copy, including the Disclaimer and Privacy text. Then set `SITE.draft` to `false` to remove the review banner.
3. Delete the `<meta name="robots" content="noindex, nofollow">` line so search engines can index the page.
4. Add `<link rel="canonical">`, `og:url` and `og:image` once the real domain is known, and change `SITE_DOMAIN` in the workflow.
5. Texas lawyer advertising rules apply to law firm websites (Texas Disciplinary Rules of Professional Conduct, Part VII). The attorney decides whether the homepage needs to be filed with the State Bar's Advertising Review Committee.

## Fonts

Barlow Condensed (© 2017 The Barlow Project Authors) and Libre Caslon Text (© 2012 The Libre Caslon Text Project Authors) are embedded in the page. Both are licensed under the [SIL Open Font License 1.1](https://openfontlicense.org).
