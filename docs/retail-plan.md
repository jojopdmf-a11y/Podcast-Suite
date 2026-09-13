# CougarCalc Podcast Suite — path to a real download (internal)

This is the working plan, not a public page. Public copy is `privacy-policy.md` and `terms.md` (port those to cougarcalc.com).

Last updated: September 13, 2026

---

## Decisions (locked unless Jeffrey changes them)

| Topic | Choice |
|---|---|
| Apple Developer + notarize | Yes — Jeffrey getting the $99 account soon |
| How customers get the apps | **Download from cougarcalc.com** (disk image or zip), not git |
| Mac App Store | **No** |
| Payments | **Paddle** → payout to **Novo** |
| Product | **One Podcast Suite license** unlocks Stripper + Mixer + Leveler |
| Trial | **14 days, full features**, same build as paid |
| Macs per license | **Two** (studio + laptop) |
| After trial | Paste a license key; Buy opens the website checkout |

---

## Trial and authorization (the plan)

Paddle takes the money and the tax. **Paddle Billing does not mint Mac license keys for us.** We do not put a Paddle SDK inside the audio apps.

### What the customer sees

1. Download the Suite from cougarcalc.com (signed/notarized when the Developer account is live).
2. First launch starts a **14-day clock** stored in **Keychain** on that Mac. Everything works, including export.
3. A small **License** status in About: “Trial · 11 days left” or “Licensed.”
4. Day 15: processing/export stops until they **Buy** (browser → Paddle checkout) or **Paste license**.
5. After a valid key is pasted, the same app keeps working **offline**. A studio Mac does not need the internet to mix.

### What we build in the apps (no Paddle account required to start)

- Keychain trial start date  
- License field + Buy button (Buy = cougarcalc.com checkout URL)  
- Local check of a **signed** key (public key inside the app; private key never ships)

### What happens when someone pays

1. Paddle checkout on the site (overlay or hosted). Card data never hits our server.
2. Paddle emails the receipt. We send (or Paddle’s fulfillment email includes) the **suite license key**.
3. Early on, Jeffrey can send keys by hand from a small list. When volume grows, a Paddle `transaction.completed` webhook mints and emails a key automatically.

### Why not lock the key to one hardware ID on day one

Podcasters use a desk Mac and a laptop. Tight machine-locking creates support mail. Two Macs, honor system, revoke a key if it is posted in public. Tighten later only if it is actually a problem.

### Refunds / chargebacks

Paddle refunds → we deactivate that key on our list. The app can optionally re-check online **when it has a network**, and **fail open** if the Mac is offline (do not punish a licensed user on a plane).

---

## Apple Developer (when the account is ready)

Jeffrey keeps the account password. We will need, later:

- Team ID (public)  
- A **App Store Connect API key** or notary credentials in the *build environment* — not the Apple ID password in chat  

Then: Developer ID sign → notarize → staple → wrap a **.dmg** → put the file on cougarcalc.com.

Until that exists, Update.command / git remains the desk workflow. Customers should not be sent that path.

---

## Website download

- One page: what the Suite is, Mac requirements (already drafted in `cougarcalc-system-requirements.md`), **Download**, **Buy**, Privacy, Terms  
- Direct links to Privacy and Terms from each app’s About box  
- Sparkle (quiet in-app updates) comes **after** the first notarized dmg is selling. Same apps, new feed URL. Not required for launch.

---

## Stripper’s extra install (Homebrew / Python)

**Do we wait until Stripper is 100% bundled before anything can ship? No.**

- Mixer and Leveler can be real, paid, notarized Mac apps first if needed.  
- **After** you ship, we can still update everything — bundling ffmpeg/Python into Stripper is an update, not a one-shot freeze.  
- What we should **not** do is take money from a stranger for Stripper while the first-run story is still “open Terminal, install Homebrew.” That feels like an unfinished product.  

Practical sequence:

1. Legal pages on the site (this PR’s copy)  
2. Notarized Mixer + Leveler downloads  
3. Trial + license in all three  
4. Stripper **bundled engine** (no Homebrew) as a dated update — can be before or shortly after first paid customers, but it should be on the public download before we call Stripper “buy this”  
5. Sparkle  

Shipping is a door you walk through. It is not a lid. Features and bundling keep moving.

---

## Next concrete slices (when Jeffrey says go)

1. Put `privacy-policy.md` and `terms.md` on cougarcalc.com (`/privacy`, `/terms`). Lawyer pass on entity + governing law.  
2. Apple Developer account → notarized dmg.  
3. Implement the 14-day Keychain trial + license paste in the three apps (Buy URL can be a placeholder until Paddle checkout exists).  
4. Paddle product + Novo payout; then wire fulfillment email.  
5. Bundle Stripper’s engine.
