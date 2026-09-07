# Recommended Setup: Tutorial Videos & Walkthrough Screenshots

This document captures the recommended toolchain, production workflow, and hosting strategy for producing visual walkthroughs (screenshots and tutorial videos) for `guix-platform-install`.

---

## 1. Toolchain Recommendations

### Video Recording & Screencasts

| Tool | Platform | Best For | Strengths |
|---|---|---|---|
| **[Screen Studio](https://www.screen.studio/)** | macOS | Primary tutorial video | Automatically applies smooth mouse follow-zooms, high-resolution backdrops, rounded corners, and hides sensitive desktop clutter. Delivers high-production-value video with zero manual keyframing. |
| **[OBS Studio](https://obsproject.com/)** | Cross-platform | Long-form / multi-scene capture | Free and open-source. Ideal for fixed-layout side-by-side terminal + browser capture without auto-zoom or cloud dependencies. |
| **[Loom](https://www.loom.com/)** | Web / macOS | Quick feedback / async sharing | Instant cloud link, camera bubble, automatic transcripts. Best for quick informal walkthroughs shared directly with collaborators. |
| **[asciinema](https://asciinema.org/)** | CLI (Linux/macOS) | Pure terminal recordings | Records lightweight terminal sessions into copy-pasteable text scripts. Excellent for embedding interactively in web pages without heavy video assets. |

### Screenshots & Clips

| Tool | Platform | Best For | Strengths |
|---|---|---|---|
| **[CleanShot X](https://cleanshot.com/)** | macOS | Documentation screenshots & short GIFs | Window snapping with clean shadows, auto-hiding desktop icons, quick annotations, and direct export to optimized GIF / MP4 clips. |
| **macOS Native (`Cmd+Shift+4` + Space)** | macOS | Standard documentation screenshots | Free, built-in window capture with native drop shadow. |

---

## 2. Walkthrough Content Structure

For a clean, 5–8 minute end-to-end tutorial demonstrating Guix on Oracle:

### Act 1: The Setup & Image Preparation (Terminal)
- Open terminal and run:
  ```sh
  git clone https://github.com/durantschoon/guix-platform-install.git
  cd guix-platform-install
  make wizard
  ```
- Demonstrate the wizard:
  - Validates pre-requisites (OCI CLI, SSH keys).
  - Downloads and verifies the published generic QCOW2 image checksum.
  - Uploads the image to Oracle Object Storage and creates the Custom Image.
  - Pauses with the step-by-step instructions for launching in OCI Console.

### Act 2: OCI Console Walkthrough (Browser)
- Open a clean browser window (preferably dark mode, no personal bookmarks).
- Navigate to **Compute -> Instances -> Create Instance**.
- Show selecting the imported **Custom Image**.
- Show configuring VM shape (**VM.Standard.A1.Flex** 4 OCPU / 24 GB RAM or **VM.Standard.E2.1.Micro**).
- **Critical Moment**: Show pasting the SSH Public Key in the **Add SSH keys** section (highlighting that this triggers the instance metadata SSH key injection service).
- Click **Create** and wait for the instance state to turn green (`RUNNING`).
- Copy the **Public IP Address**.

### Act 3: First-Boot Verification & Personal Configuration (Terminal)
- Paste the Public IP back into `make wizard` (which persists it into `.env` automatically).
- Demonstrate connecting:
  ```sh
  make ssh
  ```
- Demonstrate running the personal setup:
  ```sh
  make personal-setup
  # or with agent forwarding for private repos / git push:
  make personal-setup AGENT=1
  ```
- Show `personal-config.scm` bootstrapping dotfiles/packages on the freshly installed Guix system.

---

## 3. Video Hosting & Distribution Strategy

1. **YouTube (Public or Unlisted)**:
   - **Primary hosting venue** for permanent documentation videos.
   - Embeds cleanly into GitHub Pages (`durantschoon.github.io/guix-platform-install`) and GitHub README markdown.
   - Supports 4K/1080p60, chapters/timestamps, subtitles, and search discovery.

2. **GitHub Releases / Repository Media**:
   - Short 10–20 second clips (e.g. `make wizard` flow) converted to high-quality GIFs or lightweight `<video>` MP4s hosted in repository releases or GitHub issue media storage.
   - Used for quick visual hooks directly in the `README.md`.

3. **Why avoid Twitch for permanent guides**:
   - Twitch VODs expire after 14–60 days unless manually exported.
   - Twitch focuses on livestream interaction rather than indexed, timestamped reference tutorials.
