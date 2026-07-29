#!/bin/bash
# /usr/local/bin/audio-hp.sh
# Forca a saida de audio para HEADPHONE (HP), ignorando o estado anterior.

STATE_FILE="/var/local/audio_path"
CARD=0

# Cria a pasta de estado automaticamente, se ainda nao existir
sudo mkdir -p /var/local

echo "=== Ativando saida: HEADPHONE (HP) ==="

amixer -c $CARD sset 'Playback Path' HP > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Erro: nao consegui trocar 'Playback Path' para HP"
    exit 1
fi

# Salva o estado, pra o audio-reinit.sh saber qual usar apos reboot/resume
echo "HP" | sudo tee "$STATE_FILE" > /dev/null

# Volume audivel, mic mutado
amixer -c $CARD sset 'Playback' 237 > /dev/null 2>&1
amixer -c $CARD sset 'Record' 0 > /dev/null 2>&1

# Persiste no ALSA state
sudo alsactl store 0 2>/dev/null

# Som de confirmacao
TEST_SOUND="/usr/share/sounds/alsa/Front_Center.wav"
if [ -f "$TEST_SOUND" ]; then
    aplay "$TEST_SOUND" > /dev/null 2>&1
fi

echo "=== Audio agora em: HP ==="
