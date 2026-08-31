# zone9-agent

Proxmox cluster'ınızda çalışan zone9 yürütücüsü.

Agent **yalnızca dışarı** bağlanır (panel API'si, 443): içeri port açılmaz,
Proxmox token'ınız bu makinede kalır, panel onu hiç görmez.

## Kurulum

    curl -fsSL https://zone9.cloud/install.sh | sudo sh

Sonra `/etc/zone9/regions.yaml` dosyasını düzenleyin ve panelden aldığınız
kayıt token'ı ile eşleştirin:

    zone9-agent register --token z9r_...
    systemctl enable --now zone9-agent

## İndirmeler

Son sürüm: [releases/latest](https://github.com/z9cloud/zone9-agent/releases/latest)

- `zone9-agent-linux-amd64`
- `zone9-agent-linux-arm64`

Kaynak kod zone9 deposundadır; burası yalnızca dağıtım (binary + kurulum script'i).
