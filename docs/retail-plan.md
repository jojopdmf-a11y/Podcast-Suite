# CougarCalc PodStudio — path to a real download (internal)

This is the working plan, not a public page. Public copy is `privacy-policy.md` and `terms.md` (port those to cougarcalc.com).

Last updated: September 14, 2026

---

## Decisions (locked unless Jeffrey changes them)

| Topic | Choice |
|---|---|
| Apple Developer + notarize | Yes — Jeffrey getting the $99 account soon |
| How customers get the apps | **Download from cougarcalc.com** (disk image or zip), not git |
| Mac App Store | **No** |
| Payments | **Paddle** → payout to **Novo** |
| Products | **Each app sold separately**, plus a **PodStudio bundle** (all three, cheaper than buying à la carte) |
| Demo | **No 14-day full trial.** Unlicensed = demo forever. Output is not a clean deliverable. |
| Stripper demo | Export only the **first 7 minutes** of each stem (not the whole episode) |
| Mixer / Leveler demo | Exported file gets **~1 second of white noise every 2 minutes** |
| Macs per license | **Two** (studio + laptop) |
| After purchase | Paste a license key; Buy opens the website checkout for that SKU |

---

## Why not a 14-day full trial

These apps finish a job. Fourteen clean days is enough to strip, mix, and level a bunch of episodes and never pay. A clock also punishes the person who opens Stripper once, gets busy, and comes back on day 16.

Demo **marks the file**, not the calendar. They can evaluate for a year. They cannot hand a client a clean master.

---

## Demo mode (what we will build)

Same download for demo and paid. About shows **DEMO** or **Licensed**. Buy / paste key per app.

| App | Unlicensed output |
|---|---|
| **PodStripper** | Writes only the **first 7 minutes** of each speaker stem and Music/SFX (files may still be named normally; duration is short or the rest is silence — prefer **short files** so it is obvious). Enough to hear split quality. Not a show. |
| **PodProducer** | Play can stay clear so they can mix. **Bounce / export** inserts **1 second of white noise every 2 minutes** of program. Status line: “Demo — licensed bounce is clean.” |
| **PodLeveler** | Same as PodProducer: hear POST while playing; **Export Leveled** is noised. |

If people start recording the Mixer/Leveler output with a loopback, we can also noise the live output later. Day-one protection is the **file they save**.

Licensed copy: no noise, full Stripper duration.

---

## SKUs (Paddle)

Four one-time products:

1. PodStripper  
2. PodProducer  
3. PodLeveler  
4. **PodStudio** (all three) — price below 1+2+3  

License key payload says which app IDs it unlocks. A PodStudio key unlocks all three. Buying PodProducer later while already owning PodStripper is a second key (or we later offer “upgrade to PodStudio” credit — not required for launch).

Website: Download (all three demos), Buy this app, Buy the suite.

---

## Authorization

Paddle takes the money and the tax. **Paddle Billing does not mint Mac license keys.** No Paddle SDK inside the audio apps.

1. Checkout on cougarcalc.com for the SKU they picked.  
2. Email a **signed key** for that SKU (hand-sent at first; webhook later).  
3. Paste in the app → Keychain. Works **offline** after that.  
4. Two Macs, honor system. Revoke if a key is posted in public.

Refund → deactivate that key. Online re-check only when the Mac has a network; **fail open** if offline.

---

## Apple Developer (when the account is ready)

Jeffrey keeps the account password. We will need, later:

- Team ID (public)  
- A **App Store Connect API key** or notary credentials in the *build environment* — not the Apple ID password in chat  

Then: Developer ID sign → notarize → staple → wrap a **.dmg** → put the file on cougarcalc.com.

Until that exists, Update.command / git remains the desk workflow. Customers should not be sent that path.

---

## Website download

- Pages: what each app is, Mac requirements, **Download**, **Buy PodStripper / PodProducer / PodLeveler / PodStudio**, Privacy, Terms  
- Sparkle comes **after** the first notarized dmg is selling  

---

## Stripper’s extra install (Homebrew / Python)

**Shipping is not a freeze.** PodProducer and PodLeveler can be paid, notarized Mac apps while PodStripper still grows.

The Mac app now **bundles** `uv` plus the engine source. First open installs the Python/ML stack into `~/Library/Application Support/CougarCalc/Podcast Stripper` (about 2 GB, once). Customers should not install Homebrew. Cosmetic and model updates can still ship after that.

Do not take money for Stripper until a notarized build does this first-open install without Terminal.

---

## Next concrete slices (when Jeffrey says go)

1. Port updated `privacy-policy.md` / `terms.md` to cougarcalc.com.  
2. Apple Developer → notarized dmg (sign the nested `uv` binary too).  
3. Implement **demo marks** + license paste in each app (Buy URL per SKU).  
4. Paddle catalog: 4 products → Novo; then fulfillment email.
