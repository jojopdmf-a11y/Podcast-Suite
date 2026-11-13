# Privacy Policy — CougarCalc PodStudio

**Public copy for [cougarcalc.com/privacy](https://cougarcalc.com/privacy).** Website edits happen in the CougarCalc site repo. Keep this file as the source of truth and port it over.

**Draft for lawyer review.** This describes how the apps actually work today. Have a lawyer confirm entity name, governing law, and Paddle wording before you treat it as final.

**Effective date:** September 13, 2026  
**Contact:** hello@cougarcalc.com

---

## Short version

CougarCalc PodStudio (PodStripper, PodProducer, and PodLeveler) processes your audio **on your Mac**. We do not run a cloud render farm. We do not want your episodes. Card payments, when you buy, go through **Paddle** (they are the seller of record for checkout). Stripper includes the speaker model. You do not need a Hugging Face account.

---

## Who we are

**CougarCalc** publishes PodStudio and the site at [cougarcalc.com](https://cougarcalc.com).

Questions: **hello@cougarcalc.com**

---

## What the apps do

1. **PodStripper** — one mixed episode in; one WAV per speaker plus a Music/SFX track, out.
2. **PodProducer** — polish those stems (or other audio you drop) and bounce. You can also record from an audio interface on this Mac. That audio stays in the folder you chose. PodProducer asks for Microphone permission only to reach that interface; it does not upload the take.
3. **PodLeveler** — loudness / maximizer on a finished mix.

They are Mac apps you download and run locally. They are not a website tool that uploads a file to us.

---

## Audio files

Your recordings, stems, mixes, bounced WAVs, and mix settings stay **on the Mac you used** (and any folder or drive you choose).

We do **not**:

- upload your audio to CougarCalc servers
- listen to your shows
- use your episodes to train models

If you email us a file for support, that is only because you attached it. We will not ask you to send an episode unless you offer.

---

## What stays on your Mac

Typical local data:

| What | Where |
|---|---|
| Episodes and exports | Folders you pick |
| PodProducer “Save Mix” JSON | Next to your tracks, on disk |
| PodLeveler personal loudness presets | On this Mac |
| PodStripper output folder preference | On this Mac |
| Optional backup token (PodStripper) | **macOS Keychain**, only if you add one. The usual app does not need it. |
| License key for an app you bought | **macOS Keychain** on this Mac |

Uninstalling the app does not automatically delete your audio. The Keychain item can be removed from PodStripper **Settings → Remove**, or from Keychain Access.

---

## Speaker model (PodStripper only)

Speaker detection uses **pyannote/speaker-diarization-community-1**. That model is **included with PodStripper**. It is licensed under **CC-BY-4.0**. Credit for the authors is in the app (About and Settings) and in `Podcast Stripper/NOTICE`. CougarCalc does not claim to own the model.

You do **not** need a Hugging Face account to split an episode. The episode is processed on this Mac. It is not uploaded to CougarCalc or to Hugging Face.

When the app is built, a developer may use a Hugging Face token **once** to download that model. The token is not shipped in the app, not stored in the project, and not given to you.

Settings still has a token field. It is an **optional backup** if a copy of the app is missing the included model. If you never paste a token, nothing is stored. If you do, it stays in the **macOS Keychain** and is used only to download a replacement model.

The first time you open PodStripper it still installs its engine on this Mac (about 2 GB, needs Wi-Fi). That install is the Python tools, not a Hugging Face login. PodProducer and PodLeveler do not use this speaker model.

---

## The website and email

[cougarcalc.com](https://cougarcalc.com) is the marketing and download site. It is separate from the apps.

If you email **hello@cougarcalc.com**, we keep that thread long enough to help you. We are not building a marketing list from support mail unless you ask to be on one.

If the site later uses cookies or a simple analytics tool, this page will be updated to say so. **Today the apps themselves do not include analytics or crash reporters.**

---

## Buying (Paddle)

When paid downloads are live, checkout is handled by **Paddle**. Paddle is the **merchant of record**: they collect payment, tax, and card details. We do not see your full card number.

We expect to receive what we need to fulfill an order (typically **name, email, what you bought, and that payment succeeded**) so we can send a license and help with support.

Paddle’s privacy policy applies to the payment form. Payouts from Paddle to our business bank (**Novo**) are our accounting, not a second copy of your card.

Refunds are handled through Paddle’s process (and we can still help at hello@cougarcalc.com).

---

## Accounts

The Mac apps do **not** require a CougarCalc login. There is no “sign in with Apple” inside PodStripper, PodProducer, or PodLeveler today.

A purchase email and license key are not a public profile. The Mac apps do not ask you to create a Hugging Face account.

---

## Children

The apps are for people who make podcasts and other audio. It is not directed at children under 13. Do not buy or use it on behalf of a child in a way that would put their personal data in the apps.

---

## Sharing

We do not sell your personal information.

We share only what a tool requires:

- **Paddle** — checkout and tax  
- **Hugging Face** — only if you add the optional backup token, and only to download a missing speaker model. The usual app does not send your episode there.  
- **Email** — if you write to us  
- **Apple** — if we use their notary/update infrastructure for signed Mac apps (they see that a build was notarized, not your audio)

We may disclose information if required by law.

---

## How long we keep it

Support email: until the issue is done, then ordinary mailbox retention.

Purchase records: as long as tax and bookkeeping require (Paddle also keeps their copies).

We never receive your audio in the normal use of the apps, so there is nothing for us to “delete from the cloud.”

On your Mac, you control files and Keychain items.

---

## Your choices

- Use any of the apps with no Hugging Face account  
- Remove an optional PodStripper backup token in Settings, if you added one  
- Decline a purchase  
- Ask us at hello@cougarcalc.com to correct or delete support mail we hold  

If privacy law in your region gives you extra rights (access, deletion, portability), email us. We will work through it in plain language.

---

## Changes

If this policy changes in a real way, we will update the date at the top and post the new text at cougarcalc.com/privacy. Continued use after that date means the new text applies. We will not silently start uploading your audio; that would be a different product, and we would say so clearly.

---

## Contact

CougarCalc  
hello@cougarcalc.com  
https://cougarcalc.com
