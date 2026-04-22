# rclone-WebDAV-Nemo-RAM-Cache

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/shell-bash-brightgreen.svg)](https://www.gnu.org/software/bash/)
[![rclone](https://img.shields.io/badge/rclone-v1.50+-blue.svg)](https://rclone.org/)

Uno script Bash avanzato che trasforma **qualsiasi backend supportato da rclone** (Google Drive, MEGA, S3, WebDAV, ecc.) in un **mount locale WebDAV ad alte prestazioni** integrato nativamente con il file manager **Nemo** (e l'ecosistema GNOME/GVFS).

Lo script utilizza una **cache VFS ospitata interamente in RAM (`tmpfs`)**, calcolata dinamicamente in base alla memoria effettivamente disponibile, garantendo velocità massime in lettura e azzerando l'usura del disco (SSD/HDD) per i file temporanei.

---

## ✨ Caratteristiche Principali

- 🖥️ **Menu CLI Interattivo**: Rileva automaticamente i tuoi remote rclone configurati e ti permette di scegliere quale montare.
- ⚡ **Cache RAM Dinamica (`tmpfs`)**: Calcola la `MemAvailable` (memoria realmente libera del sistema) e crea un ramdisk dedicato allocando una percentuale a tua scelta (default: 80%).
- 🚀 **Zero-Copy & Zero-Wear**: Usa `--vfs-cache-mode full` direttamente sulla RAM. Ideale per streaming video pesanti o manipolazione di molti file senza usurare il disco locale.
- 🔗 **Integrazione Nativa GVFS**: Monta la risorsa tramite `gio mount`, rendendola disponibile a livello di sistema operativo come un normale disco di rete.
- 🏷️ **Naming Dinamico (GTK Bookmarks)**: Crea un segnalibro temporaneo nella sidebar di Nemo col **nome esatto del tuo backend rclone** (es. `Mega`, `Gdrive`), bypassando le etichette generiche IP/Porta di GVFS.
- 🧹 **Graceful Teardown (Ctrl+C)**: Cattura i segnali di uscita per chiudere Nemo, smontare in modo sicuro il volume GVFS (`gio mount -u`), terminare rclone, liberare la RAM (`umount tmpfs`) e rimuovere il segnalibro temporaneo.

---

## 📋 Prerequisiti

Assicurati che il tuo sistema abbia i seguenti pacchetti installati:

```bash
# Ubuntu / Debian / Linux Mint
sudo apt update
sudo apt install rclone nemo libglib2.0-bin coreutils netcat-openbsd psmisc lsof
```
*Nota: `libglib2.0-bin` fornisce il comando `gio`.*

Devi avere almeno un remote configurato in rclone:
```bash
rclone config
```

---

## 🚀 Utilizzo

1. **Scarica lo script** e rendilo eseguibile:
   ```bash
   chmod +x rclone-webdav.sh
   ```

2. **Esegui lo script**:
   ```bash
   ./rclone-webdav.sh
   ```

3. **Interazione**:
   - Verrà mostrato l'elenco dei tuoi remote rclone. Digita il numero corrispondente.
   - Scegli la percentuale di RAM libera da dedicare alla cache (premi `Invio` per usare l'80% di default).
   - Lo script chiederà la password di `sudo` (necessaria per montare il `tmpfs` e assegnare i permessi corretti).

4. **Fatto!**
   - Nemo si aprirà automaticamente.
   - Troverai il tuo remote nella sidebar di sinistra sotto forma di segnalibro.
   - Per smontare tutto in modo pulito, torna al terminale e premi `Ctrl+C`.

---

## ⚙️ Configurazione Avanzata

Puoi modificare il comportamento di default editando le variabili in testa allo script `rclone-webdav.sh`:

```bash
# =========================
# Configurazione fissa
# =========================
RCLONE_ADDR="127.0.0.1"       # Indirizzo di bind del server WebDAV interno
RCLONE_PORT="2022"            # Porta (cambiala se 2022 è già in uso)
RCLONE_USER="benjiworld"      # Username fittizio per il WebDAV locale
RCLONE_PASS=""                # Password fittizia per il WebDAV locale
RCLONE_MIN_FREE_SPACE="512M"  # Spazio minimo che rclone lascia libero nel ramdisk

DEFAULT_RAM_PERCENT="80"      # Percentuale di default della MemAvailable da usare
MIN_CACHE_MIB=512             # Dimensione minima assoluta del ramdisk in MB
# =========================
```

---

## 🧠 Dettagli Tecnici dell'Architettura

1. **Memoria (Il problema di `MemFree`)**
   Lo script non usa `MemFree`, ma interroga `/proc/meminfo` per ottenere `MemAvailable`. Questo è il modo corretto su Linux per sapere quanta memoria è allocabile per nuove applicazioni senza innescare lo swapping, poiché tiene conto della page cache rilasciabile.

2. **Perché `tmpfs` esplicito invece di `/dev/shm`?**
   Invece di appoggiarsi passivamente a `/dev/shm` (che ha un limite fisso al 50% della RAM totale a prescindere dal consumo attuale), lo script usa `sudo mount -t tmpfs` per creare un ramdisk su misura (`size=Xk`), calcolato dinamicamente al momento dell'esecuzione, garantendo le massime performance senza causare OOM (Out Of Memory) killer events.

3. **Il problema GVFS I/O Error**
   I mount GVFS non sono file system reali ma astrazioni POSIX-like. L'uso di comandi come `find` su `/run/user/1000/gvfs` causa spesso `Input/output error`. Questo script elude il problema utilizzando esclusivamente i comandi nativi `gio mount` e `gio mount -u` per il ciclo di vita del mount.

4. **Gestione Processi Orfani**
   Il blocco `trap cleanup INT TERM EXIT` assicura che in nessun caso (errore dello script, interruzione dell'utente, chiusura del terminale) vengano lasciati server `rclone` in background in ascolto su porte orfane, o porzioni di RAM bloccate da `tmpfs` non smontati. Utilizza `fuser` e `lsof` per forzare l'unmount (`umount -l`) se necessario.

---

## 🐛 Risoluzione dei Problemi Comuni

- **`Error: port 2022 is already in use`**
  Un'istanza precedente potrebbe non essersi chiusa correttamente. Lo script ti mostrerà il PID. Uccidilo con `kill -9 <PID>` o cambia la variabile `RCLONE_PORT` nello script.
- **Nemo mostra "127.0.0.1" invece del nome del remote**
  Lo script inietta un segnalibro in `~/.config/gtk-3.0/bookmarks`. Assicurati di cliccare sul segnalibro appena creato nella barra laterale, e non di navigare la rete tramite la voce "Rete" di Nemo.

---

## 📄 Licenza

Distribuito sotto licenza MIT. Vedi `LICENSE` per maggiori informazioni.

---
*Costruito per massimizzare le performance di Rclone su desktop Linux.*
