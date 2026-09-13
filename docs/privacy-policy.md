# Privacy Policy — CougarCalc Podcast Suite

**Public copy for [cougarcalc.com/privacy](https://cougarcalc.com/privacy).** Website edits happen in the CougarCalc site repo. Keep this file as the source of truth and port it over.

**Draft for lawyer review.** This describes how the apps actually work today. Have a lawyer confirm entity name, governing law, and Paddle wording before you treat it as final.

**Effective date:** September 13, 2026  
**Contact:** hello@cougarcalc.com

---

## Short version

CougarCalc Podcast Suite (Podcast Stripper, Fixer Mixer, and Lil Leveler) processes your audio **on your Mac**. We do not run a cloud render farm. We do not want your episodes. Card payments, when you buy, go through **Paddle** (they are the seller of record for checkout). Stripper’s speaker model comes from **Hugging Face** under *your* login, not ours.

---

## Who we are

**CougarCalc** publishes the Podcast Suite and the site at [cougarcalc.com](https://cougarcalc.com).

Questions: **hello@cougarcalc.com**

---

## What the apps do

1. **Podcast Stripper** — one mixed episode in; one WAV per speaker plus a Music/SFX track, out.
2. **Fixer Mixer** — polish those stems (or other audio you drop) and bounce.
3. **Lil Leveler** — loudness / maximizer on a finished mix.

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
| Mixer “Save Mix” JSON | Next to your tracks, on disk |
| Leveler personal loudness presets | On this Mac |
| Stripper output folder preference | On this Mac |
| Hugging Face token (Stripper) | **macOS Keychain** (not in the project, not on our servers) |
| Future license key / trial clock | **macOS Keychain** on this Mac |

Uninstalling the app does not automatically delete your audio. The Keychain item can be removed from Stripper **Settings → Remove**, or from Keychain Access.

---

## Hugging Face (Podcast Stripper only)

Speaker detection uses the **pyannote speaker-diarization-community-1** model. Hugging Face, not CougarCalc, hosts that model and its terms.

You:

1. Create a Hugging Face account if you do not have one  
2. Accept *their* model terms  
3. Paste a **read** token into Stripper Settings  

The token is stored in **Keychain**. The app uses it to **download the model onto your Mac** and to run speaker detection **locally**. Your episode is not sent to CougarCalc. Hugging Face’s own privacy policy applies to their account, website, and model download.

You can skip Stripper’s speaker step only by not using Stripper. Mixer and Leveler do not need a Hugging Face account.

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

The Mac apps do **not** require a CougarCalc login. There is no “sign in with Apple” inside Stripper, Mixer, or Leveler today.

A purchase email and license key are not a public profile. Hugging Face is a separate account you already use for the speaker model.

---

## Children

The Suite is for people who make podcasts and other audio. It is not directed at children under 13. Do not buy or use it on behalf of a child in a way that would put their personal data in the apps.

---

## Sharing

We do not sell your personal information.

We share only what a tool requires:

- **Paddle** — checkout and tax  
- **Hugging Face** — your token and their model download, which you set up  
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

- Use Mixer and Leveler with no Hugging Face token  
- Remove the Stripper token in Settings  
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
