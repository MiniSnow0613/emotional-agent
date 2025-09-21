# Emotion AI Agent
This Emotional AI Agent monitors your mood in real time and steps in when it detects you’re feeling down. It opens a friendly chatbot that lets you choose what helps most in the moment—queue a YouTube Music track, start a guided mindfulness meditation, launch a light stress-relief mini-game, or simply talk it out. The goal is simple: provide timely, supportive interactions that help you reset and feel better.

## Installation
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
>The project includes a Dockerized database integration that’s still in progress. Several modules already expect a database running in Docker, so installing Docker now avoids setup issues and makes future updates smoother.
2. Clone the repository and switch to the project folder:
    ```
    git clone https://github.com/MiniSnow0613/emotional-agent
    cd <project-folder>
    ```
3. Download the installer bootstrapper (.exe) from https://drive.google.com/file/d/1tBed4w0aKPjwtN5wN2Cxeet3h5NriZ5x/view?usp=sharing and save it into the cloned folder.
*This lightweight network installer will fetch the full setup package automatically.*
4. Run the bootstrapper (double-click the .exe) and follow the prompts to complete installation.

## Launcher Script
Launch via PowerShell from the project folder:
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher.ps1
```

## Usage
1. The Lemonade Launcher window opens. Click One-Click START to start all servers.

   <img width="500" alt="image" src="https://github.com/user-attachments/assets/865c2fcd-d41c-4405-a90e-8241c3459c09" />
   
2. After a short initialization period, the Emotional AI Agent chat box becomes available.
3. On first launch, the agent performs a mood detection step (this can take a moment).
    * If it detects that you’re not feeling well, it will ask whether to open the main menu.
    * Reply `/ok` to enter the menu, or `/no` to skip.
   
   <br><img width="500" alt="image" src="https://github.com/user-attachments/assets/db4d889d-8c7a-423c-8650-a98a377f68c1" /><br/>
    
5. Ongoing checks: Every 10 minutes, the agent automatically re-checks your mood and may prompt again to open the main menu if needed.
6. Inside the main menu, you can choose:
    * `/music` — Play a YouTube Music track.
    * `/mind` — Start a guided mindfulness session.
    * `/game` — Launch a light stress-relief mini-game.
    * `/chat` — Chat with the agent.
   
   <br><img width="500" alt="image" src="https://github.com/user-attachments/assets/bfbf0c23-8c9d-4edd-9086-89872db72c89" /><br/>

## Features by Tool
#### `/music` — YouTube Music playback
* What it does: Opens YouTube Music in your browser based on the artist or genre you specify.
* Examples:
    * `/music YOASOBI`
    * `/music lo-fi`

#### `/mind` — Guided mindfulness audio
* What it does: Plays a mindfulness/meditation voice track.
* Choose by index: You can specify which audio file (by its index in the local folder).
* Examples:
    * `/mind` — play the default track
    * `/mind 3` — play the 3rd audio file

#### `/game` — Relaxing jigsaw puzzle (in browser)
* What it does: Opens a web-based puzzle designed for relaxation.
* You can: choose the image, select the puzzle layout, and save images you’ve completed.
* Examples:
    * `/game` — open the puzzle home

<img width="500" alt="image" src="https://github.com/user-attachments/assets/0e6f8596-f602-41c9-958c-a1e1a32a5d96" />

#### `/chat` — Private, therapist-style conversation
* What it does: Chat with a supportive AI that behaves like a mental-health coach
* Privacy: Runs on a local model, so you can safely share your situation.
* Shortcut hub: From here, you can also trigger music, mindfulness, or the puzzle game without leaving chat.
* Examples:
    * `/chat` — start talking

<img width="500" alt="image" src="https://github.com/user-attachments/assets/8045fb94-93b6-4c26-a5a6-11a81be67b79" />


## Troubleshooting

**Issue:** After installing Lemonade Server, **GGUF** or **NPU** models fail to start.
**Cause:** Outdated **AMD GPU driver** (and related runtimes).
**Fix:** Update to the latest **AMD Software: Adrenalin Edition** driver, then **reboot** and relaunch.

## Demo Video
Watch the demo: https://drive.google.com/file/d/1XloGdozNn6EWx1JCt_B_CVuSYb2ildWN/view?usp=drive_link

