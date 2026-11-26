# Azure tests: Azurite, cassettes and the live suite

The Azure backend is tested in three layers (design §8, D13):

| Layer | File | Runs |
| --- | --- | --- |
| Requests: a `zu_mock_transport()` fake over the fixtures, and the cassettes replayed | `tests/testthat/test-azure.R` | everywhere, CRAN included |
| Emulator: Azurite over HTTPS with `--oauth basic`, against `deltalake` 1.7.0 | `tests/testthat/test-azure-emulator.R` | `.github/workflows/azure-emulator.yaml` |
| Live: one table on ADLS Gen2, against `deltalake` 1.7.0 | `tests/testthat/test-azure-live.R` | `.github/workflows/azure-live.yaml`, on dispatch |

## Azurite, locally

Node 22, `openssl`, and `uv` 0.7.11 for the oracle. From the package root:

```sh
d=/tmp/zulake-azurite && mkdir -p "$d/data"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -days 30 \
  -subj "/CN=zulake test CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout "$d/server.key" -out "$d/server.csr" -subj "/CN=127.0.0.1"
printf "subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > "$d/ext.cnf"
openssl x509 -req -in "$d/server.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial \
  -out "$d/server.pem" -days 30 -extfile "$d/ext.cnf"
npx --yes azurite@3.35.0 --oauth basic --cert "$d/server.pem" --key "$d/server.key" \
  --silent --location "$d/data" &

export ZULAKE_AZURITE_ENDPOINT=https://127.0.0.1:10000/devstoreaccount1
export ZULAKE_AZURITE_CA="$d/ca.pem"
export ZULAKE_AZURITE_ANSWERS="$d/answers"
R CMD INSTALL .
Rscript tools/azurite/upload.R
(cd tools/oracle && ZULAKE_AZURITE_TOKEN="$(Rscript -e 'source("../../tests/testthat/helper-azure.R"); cat(azurite_token)')" \
  uv run --frozen python azurite.py "$ZULAKE_AZURITE_ANSWERS")
Rscript -e 'devtools::test(filter = "azure")'
```

The token is `azurite_token` in `tests/testthat/helper-azure.R`: an unsigned
JWT that Azurite's `--oauth basic` accepts (it checks the audience, the
issuer's form and the expiry, not the signature). It is a test value, not a
credential: no other service accepts it.

## Recording the cassettes again

The cassettes in `tests/testthat/fixtures/cassettes/` are recorded from
Azurite, never written by hand. `test-azure.R` replays them, and checks
that none holds any piece of the token. To record them again, with Azurite
up as above:

```sh
ZULAKE_RECORD_CASSETTES=tests/testthat/fixtures/cassettes \
  Rscript -e 'devtools::test(filter = "azure-emulator")'
```

That records `cassette_session()` (open, files, read, deletion vectors) for
each table in `cassette_tables` (`helper-azure.R`). A request with a `Range`
header goes to a cassette of its own, `<table>-range-<from>-<to>.rds`,
because a cassette key ignores `Range` (pedrobtz/zuhttp#353). The
`azure-emulator` workflow records the same files on every run and uploads
them as its `cassettes` artifact.

## Live

With a token for `https://storage.azure.com` and a table:

```sh
export ZULAKE_AZURE_URI=abfss://<container>@<account>.dfs.core.windows.net/<path>
export ZULAKE_AZURE_TOKEN="$(az account get-access-token --resource https://storage.azure.com --query accessToken --output tsv)"
(cd tools/oracle && uv run --frozen python live.py /tmp/zulake-live)
ZULAKE_AZURE_ANSWERS=/tmp/zulake-live Rscript -e 'devtools::test(filter = "azure-live")'
```

or dispatch `azure-live.yaml`, whose secrets the workflow's header lists
(pedrobtz/zulake#24).
