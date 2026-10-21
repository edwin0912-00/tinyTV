# Pairing a Hisense VIDAA TV

Many VIDAA TVs accept MQTT on port 36669 only with TLS and a client certificate (the one the RemoteNOW app uses),
and then ask for a PIN shown on the TV. **tinyTV does not ship that certificate.** Get it yourself, from a source
you trust, and keep it out of git.

1. Check the TV:

   ```bash
   node scripts/tinytv-setup.mjs discover
   ```

   "TLS needs a client certificate" means you need the steps below.
2. Get the certificate pair. Community sources: `d3nd3/Hisense-mqtt-keyfiles` on GitHub; or extract it from the
   RemoteNOW app you own. Read the source before you use it.
3. Put the files in `$TINYTV_DIR/certs/` (default `~/.tinytv/certs/`): `rcm_certchain_pem.cer`, `rcm_pem_privkey.pkcs8`.
4. Clone the crypto helper (MIT): `git clone https://github.com/stevene1919/hisense_vidaa ~/.tinytv/vendor/hisense_vidaa`.
5. Pair: `pip install paho-mqtt`, then `python3 scripts/pair.py <TV-IP>`. Write the PIN from the TV into `~/.tinytv/pin.txt`.
6. Make a `.p12` for the core (password `tinytv`):

   ```bash
   openssl pkcs12 -export -in ~/.tinytv/certs/rcm_certchain_pem.cer -inkey ~/.tinytv/certs/rcm_pem_privkey.pkcs8 -out ~/Library/Application\ Support/tinyTV/remotenow.p12 -passout pass:tinytv
   ```

7. Use the same `client_id` in `config.json` as in pairing (default `tinytv_core`).

Measured on a 55A56EEVS (transport_protocol 1140): only the legacy login `hisenseservice` with this certificate
works; after pairing no token is needed. Other firmware may differ.
