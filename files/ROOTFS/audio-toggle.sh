#!/bin/bash
# /usr/local/bin/audio-toggle.sh
# Alterna entre saida de Speaker (SPK) e Headphone (HP) no codec RK817.
# Salva o estado atual em um arquivo pra o audio-reinit.sh saber qual usar
# depois de um boot ou de um resume (tela apagar/acordar).

STATE_FILE="/var/local/audio_path"
CARD=0

# Cria a pasta de estado automaticamente, se ainda nao existir
sudo mkdir -p /var/local

# Le o estado salvo, ou assume SPK se nao existir ainda
if [ -f "$STATE_FILE" ]; then
    CURRENT=$(cat "$STATE_FILE")
else
    CURRENT="SPK"
fi

# Decide o proximo estado
if [ "$CURRENT" = "SPK" ]; then
    NEXT="HP"
else
    NEXT="SPK"
fi

echo "=== Trocando audio: $CURRENT -> $NEXT ==="

# Aplica o novo path
amixer -c $CARD sset 'Playback Path' "$NEXT" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Erro: nao consegui trocar 'Playback Path' para $NEXT"
    exit 1
fi

# Salva o novo estado
echo "$NEXT" | sudo tee "$STATE_FILE" > /dev/null

# Garante volume audivel e mic mutado (ajuste os valores se quiser)
amixer -c $CARD sset 'Playback' 237 > /dev/null 2>&1
amixer -c $CARD sset 'Record' 0 > /dev/null 2>&1

# Persiste no ALSA state tambem, pra sobreviver a reboot
sudo alsactl store 0 2>/dev/null

# Toca um som curto de confirmacao
TEST_SOUND="/usr/share/sounds/alsa/Front_Center.wav"
if [ -f "$TEST_SOUND" ]; then
    aplay "$TEST_SOUND" > /dev/null 2>&1
fi

echo "=== Audio agora em: $NEXT ==="
