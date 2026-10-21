# Rencana modul opsional WhiteThroated

Status: proposal

Dokumen ini merencanakan fasilitas aplikasi di atas `WhiteThroated` tanpa
memasukkannya ke hot path core. Nama produk dan contoh API di bawah masih
bersifat rancangan; perilaku dan kontrak harus dikunci melalui proposal API,
tes, dan benchmark sebelum implementasi dianggap stabil.

## 1. Tujuan

- Menyediakan pengalaman "batteries available" tanpa menjadikan semua fitur
  sebagai biaya wajib.
- Mempertahankan `WhiteThroated` sebagai core HTTP kecil, cepat, dan dapat
  digunakan sendiri.
- Membuat setiap capability dapat dipasang secara independen melalui SwiftPM.
- Menjaga API Swift yang eksplisit tentang I/O, concurrency, penyimpanan, dan
  biaya request-time.
- Menyediakan integrasi resmi dengan implementasi pihak ketiga tanpa memaksa
  satu database, exporter, atau deployment platform.

## 2. Non-tujuan

- Memindahkan ORM, authentication, template, telemetry, atau deployment
  orchestration ke `WhiteThroatedRuntime`.
- Menyatukan handler prepared, synchronous, future, dan async ke satu abstraksi
  yang membuat jalur murah membayar `Task` atau `EventLoopFuture`.
- Menulis ulang database driver, TLS stack, compressor, atau telemetry backend
  yang sudah matang tanpa alasan correctness dan performance yang terukur.
- Mengaktifkan logging, metrics, tracing, compression, session, atau rate limit
  secara implisit.
- Menjanjikan kompatibilitas API stabil selama WhiteThroated masih pre-alpha.

## 3. Prinsip arsitektur

### 3.1 Core tetap independen

Graf dependency harus satu arah:

```text
Modul aplikasi opsional
        |
        v
WhiteThroated
        |
        v
WhiteThroatedRuntime -> WhiteThroatedHTTP1 -> SwiftNIO
```

`WhiteThroated`, `WhiteThroatedRuntime`, dan `WhiteThroatedHTTP1` tidak boleh
bergantung pada modul opsional. Modul opsional tidak boleh menambahkan konsep
framework ke runtime, seperti user identity, session, schema, ORM model, span,
atau static-file root.

Pengecualian hanya untuk hook core yang benar-benar diperlukan oleh beberapa
modul. Hook tersebut harus:

- berupa value/closure concrete, bukan service-locator global;
- dibangun ketika setup dan immutable ketika serving;
- memiliki jalur `nil`/disabled yang tidak mengalokasikan per request;
- tidak mengubah semantik prepared, sync, future, dan async responder;
- disertai benchmark sebelum/selesai jika menyentuh hot path.

### 3.2 Produk kecil, umbrella opsional

Setiap capability diterbitkan sebagai library product terpisah. Umbrella
product boleh disediakan hanya sebagai kemudahan import dan tidak boleh
mengaktifkan fitur otomatis.

Contoh bentuk package:

```swift
.library(name: "WhiteThroatedAuth", targets: ["WhiteThroatedAuth"])
.library(name: "WhiteThroatedSessions", targets: ["WhiteThroatedSessions"])
.library(name: "WhiteThroatedStaticFiles", targets: ["WhiteThroatedStaticFiles"])
.library(name: "WhiteThroatedObservability", targets: ["WhiteThroatedObservability"])
```

Keputusan awal adalah memakai **monorepo modular**: seluruh kontrak dan modul
resmi yang masih berinkubasi tinggal di repository WhiteThroated, tetapi masing-
masing merupakan SwiftPM target dan library product terpisah. Aplikasi core-only
tidak boleh menarik, menginisialisasi, atau mengeksekusi modul yang tidak dipilih.

Pemisahan repository bukan syarat modularitas binary atau dependency. Sebuah
modul baru dipindahkan menjadi package/repository terpisah setelah API integration
stabil, ownership dan release cadence-nya jelas, serta CI lintas package tersedia.

Gunakan struktur hybrid berikut dalam jangka panjang:

```text
Repository utama WhiteThroated
  - core dan runtime
  - kontrak capability
  - modul resmi yang ringan
  - integration tests lintas modul

Repository adapter resmi terpisah
  - database/vendor driver
  - Redis session/rate-limit store
  - JWT/OIDC provider
  - OpenTelemetry exporter
  - backend compression tambahan

Repository komunitas
  - integrasi vendor atau platform khusus
```

Kriteria memindahkan sebuah adapter/modul ke repository sendiri:

- membawa dependency eksternal besar atau khusus;
- memiliki release cadence atau maintainer berbeda;
- perubahan modul jarang membutuhkan perubahan core;
- API kontraknya sudah stabil dan mempunyai compatibility matrix;
- CI, platform, atau operational lifecycle-nya berbeda secara material;
- dapat berguna untuk lebih dari satu framework.

### 3.3 Setup-time first dan opt-in

- Konfigurasi dikompilasi/finalisasi sebelum `run` atau `listen`.
- Route dan middleware yang tidak memakai modul tidak menanggung lookup modul.
- Parsing request tetap lazy jika nilainya belum dibutuhkan.
- Immutable policy, schema, template metadata, dan header disiapkan saat setup.
- Blocking I/O wajib dipindahkan dari event loop ke executor yang eksplisit.
- State mutable request/connection tetap event-loop confined jika memungkinkan.

### 3.4 Provider dan adapter

Modul yang membutuhkan backend mendefinisikan kontrak kecil dan adapter resmi:

```text
API WhiteThroated -> kontrak capability -> adapter -> backend
```

Contoh: session API tidak mengetahui Redis secara langsung. Ia menggunakan
`SessionStore`; adapter Redis berada di product lain. Kontrak tidak boleh
memaksa semua backend memakai model concurrency atau transaksi yang tidak
sesuai.

### 3.5 Keamanan default

- Cookie session default ke `HttpOnly`, `Secure` saat HTTPS, dan `SameSite` yang
  terdokumentasi.
- Secret, token, cookie, authorization header, dan body sensitif tidak masuk log
  secara default.
- Static files menolak path traversal dan symlink escape sesuai policy.
- CORS default deny untuk cross-origin yang tidak dikonfigurasi.
- CSRF aktif hanya pada model autentikasi berbasis browser/cookie yang sesuai.
- Proxy headers tidak dipercaya tanpa `TrustedProxy` eksplisit.
- TLS tidak memiliki mode trust-all atau validation-off sebagai default.

### 3.6 Dependency Tier 1 / fundamental

Dependency baru wajib berasal dari Tier 1 atau fundamental. Aturan ini berlaku
untuk dependency langsung maupun transitif.

Yang dianggap Tier 1 / fundamental:

- Swift standard library dan Foundation;
- SwiftNIO dan modul resmi SwiftNIO;
- paket resmi Swift project yang bersifat low-level dan tidak dimiliki oleh
  framework web lain, seperti Swift Crypto, Swift Log, Swift Metrics, Swift
  Collections, Swift Atomics, Swift System, dan Swift Service Lifecycle;
- system library/fundamental OS interface seperti SQLite, libpq, POSIX, atau
  OpenSSL, yang diakses melalui system-library target dan tanpa menambahkan
  source implementasi non-Swift ke repository.

Yang dilarang:

- paket milik framework/ecosystem lain, termasuk seluruh paket `vapor/*`;
- paket yang secara transitif menarik framework web atau application framework
  lain;
- membungkus driver framework lain sebagai dependency adapter resmi;
- memilih paket framework hanya karena API-nya nyaman bila ada jalur
  Tier 1/fundamental yang memadai.

Jika capability membutuhkan backend yang tidak memiliki driver Tier 1 /
fundamental, pilihan yang diizinkan adalah:

1. membangun adapter Swift tipis di atas system library/fundamental interface;
2. menunda capability tersebut; atau
3. mengajukan pengecualian dependency secara eksplisit dengan review terpisah.

Menulis ulang protokol database, TLS stack, atau codec dari nol tetap bukan
default. Pengecualian tidak boleh disamarkan sebagai "adapter tipis".

Setiap dependency baru harus mencatat:

- alasan fungsional dan mengapa Tier 1/fundamental tidak cukup;
- lisensi dan ownership;
- transitive dependency graph;
- allocation, concurrency, dan lifecycle cost;
- exact pin di `Package.resolved`;
- dampak benchmark bila menyentuh hot path.

## 4. Katalog modul

### 4.1 Authentication, sessions, validation

Kategori ini dipecah agar API token stateless tidak perlu menarik session store,
CSRF, OpenAPI, atau rate limiter.

#### `WhiteThroatedAuth`

Tanggung jawab:

- kontrak `Authenticator`, `Principal`, `Credential`, dan `AuthorizationPolicy`;
- middleware autentikasi untuk bearer token, API key, dan session principal;
- route/group authorization berdasarkan policy, role, atau permission;
- response `401` dan `403` yang konsisten;
- opt-in hooks untuk audit tanpa mencatat credential.

Batasan:

- password hashing menjadi adapter khusus yang memakai library kriptografi
  terawat; jangan membuat algoritme kriptografi sendiri;
- JWT/OAuth/OIDC menjadi adapter terpisah agar dependency dan network behavior
  tidak dibayar pengguna auth sederhana;
- authentication tidak boleh otomatis berarti authorization.

API kandidat:

```swift
app.use(authentication: authenticator)
app.group("/admin").authorize(AdminPolicy())
```

#### `WhiteThroatedSessions`

Tanggung jawab:

- lifecycle session ID: create, load, rotate, expire, destroy;
- signed/encrypted cookie metadata;
- kontrak `SessionStore` dengan adapter memory untuk development/test;
- adapter Redis/database sebagai product terpisah;
- TTL, idle expiration, fixation protection, dan key rotation.

Invariant utama:

- store asynchronous tidak boleh memblokir event loop;
- request tanpa akses session sebaiknya tidak melakukan decode/store lookup jika
  mode lazy dapat dipertahankan;
- session ID harus dirotasi setelah perubahan privilege/login;
- memory store bukan rekomendasi untuk multi-process production.

#### `WhiteThroatedCSRF`

Tanggung jawab:

- synchronizer token atau signed double-submit cookie;
- integrasi dengan session/cookie authentication;
- pengecualian method aman dan policy origin/referrer yang terdokumentasi;
- response kegagalan yang dapat dikustomisasi.

Tes wajib mencakup token hilang, salah, replay sesuai policy, method aman,
cross-origin, cookie attributes, dan interaksi trusted proxy/HTTPS.

#### `WhiteThroatedRateLimit`

Tanggung jawab:

- fixed window, sliding window, dan/atau token bucket;
- key resolver eksplisit: IP tepercaya, principal, API key, atau closure aplikasi;
- local in-memory limiter dan kontrak distributed store;
- `Retry-After` dan header limit yang terdokumentasi;
- bounded state dan eviction.

Limiter tidak boleh mempercayai `X-Forwarded-For` tanpa konfigurasi
`TrustedProxy`. Atomicity dan failure policy untuk distributed store harus
eksplisit: fail-open atau fail-closed, tidak tersembunyi.

#### `WhiteThroatedValidation`

Tanggung jawab:

- schema request untuk path, query, header, cookie, dan body;
- error validation terstruktur dengan lokasi field;
- integrasi `Codable` tanpa memaksa decode jika handler tidak membutuhkan body;
- batas ukuran dan kedalaman data.

#### `WhiteThroatedOpenAPI`

Tanggung jawab:

- menghasilkan OpenAPI dari metadata route/schema;
- menyajikan dokumen JSON/YAML dan UI hanya jika diaktifkan;
- menjaga schema dokumentasi dan validation berasal dari sumber kontrak yang
  sama;
- mendeteksi operation ID dan route collision saat setup.

OpenAPI bergantung pada `WhiteThroatedValidation`, bukan sebaliknya. Route biasa
harus tetap dapat didaftarkan tanpa metadata OpenAPI.

### 4.2 Database dan business services

#### `WhiteThroatedServices`

Menyediakan dependency registry ber-scope jelas:

- application singleton untuk pool/configuration immutable;
- connection/request scope hanya bila benar-benar diperlukan;
- factory dan shutdown hook;
- override yang mudah untuk test.

Registry tidak boleh melakukan runtime reflection atau global lookup pada setiap
request. Preferensi awal adalah typed application context atau generated key,
bukan dictionary `Any` yang diakses berulang di hot path.

#### `WhiteThroatedDatabase`

Tanggung jawab:

- kontrak connection pool, lease, transaction, query cancellation, dan shutdown;
- integrasi deadline/cancellation request bila backend mendukung;
- adapter resmi untuk database yang dipilih kemudian;
- observability hook tanpa dependency wajib pada exporter.

Database work harus non-blocking atau dijalankan pada executor khusus. Pool
tidak boleh dibuat per request.

Adapter database resmi wajib mengikuti aturan dependency Tier 1/fundamental pada
bagian 3.6. Paket driver milik framework lain seperti `vapor/*` tidak boleh
dipakai. Jika driver Tier 1/fundamental belum tersedia, adapter harus dibangun
di atas system library/fundamental interface atau capability ditunda sampai ada
keputusan dependency yang terpisah.

#### `WhiteThroatedPostgres` (proof adapter Fase 4)

Adapter produksi awal untuk PostgreSQL dibangun langsung di atas system library
`libpq` melalui target SwiftPM `CPostgres`:

- system library dan header deklarasi, bukan implementasi protokol non-Swift;
- actor pool dengan lease, pembuatan koneksi lazy, penggantian koneksi rusak,
  dan drain saat shutdown;
- satu serial `DispatchQueue` per koneksi fisik agar panggilan libpq yang
  blocking tidak pernah berjalan di event loop;
- cancellation melalui `PQcancel`, rollback transaksi, pemetaan SQLSTATE, dan
  pemetaan tipe PostgreSQL ke `DatabaseValue`;
- session-level advisory lock untuk migration runner.

Adapter tidak menambahkan dependency pada modul framework lain. `numeric`,
date/time, JSON, array, dan tipe extension dipertahankan sebagai teks agar
presisi tidak hilang diam-diam.

#### `WhiteThroatedORM`

Tanggung jawab tahap awal:

- typed query/model mapping di atas adapter database;
- explicit fetch/insert/update/delete;
- transaction boundaries yang terlihat;
- eager/lazy relationship behavior yang tidak mengejutkan.

ORM harus dimulai setelah database contract stabil. Hindari active-record magic,
implicit N+1 query, hidden global connection, atau query saat property dibaca.

#### `WhiteThroatedMigrations`

Tanggung jawab:

- migration ID dan checksum;
- ordered apply, status, dry-run, dan explicit rollback jika tersedia;
- locking agar dua instance tidak bermigrasi bersamaan;
- CLI executable terpisah dari server request path.

Migration tidak dijalankan otomatis saat server menerima traffic kecuali
aplikasi memilih mode tersebut secara eksplisit.

### 4.3 HTML rendering / static assets

Scope kategori ini untuk roadmap awal adalah static-file server, bukan template
engine. Secara teknis static files adalah penyajian asset, bukan rendering HTML;
nama kategori dipertahankan agar sesuai pengelompokan produk yang diminta.

#### `WhiteThroatedStaticFiles`

Tanggung jawab:

- mount satu atau lebih directory pada prefix URL;
- MIME type, index file opsional, cache policy, dan download disposition;
- `GET`/`HEAD`, conditional request, single range, dan `FileRegion`;
- precompressed `.br`/`.gz` hanya setelah negosiasi `Accept-Encoding` benar;
- fallback eksplisit untuk SPA tanpa menelan route API secara tidak sengaja.

Keamanan dan correctness:

- normalisasi percent-decoding harus dilakukan tepat satu kali dengan policy
  yang jelas;
- tolak `..`, separator tersamar, NUL, path absolut, dan root escape;
- symlink policy harus configurable dan default aman;
- tidak menampilkan directory listing secara default;
- file stat/open race dan perubahan file selama transfer harus ditangani;
- header path cepat harus tetap melalui validasi response header.

API kandidat:

```swift
app.mountStatic(
    "/assets",
    directory: assetsURL,
    options: .production
)
```

### 4.4 Observability

#### `WhiteThroatedObservability`

Umbrella integrasi untuk tiga capability independen:

- structured logging;
- metrics;
- tracing.

Subtarget atau product adapter dapat berupa:

- `WhiteThroatedLogging` untuk `swift-log` atau sink internal yang dipilih;
- `WhiteThroatedMetrics` untuk counter, gauge, dan histogram;
- `WhiteThroatedTracing` untuk W3C Trace Context/OpenTelemetry adapter.

Data request standar:

- request/correlation ID;
- method dan route template, bukan raw URI sebagai label metrics;
- status class, duration, response bytes, dan error category;
- connection/stream counters yang cardinality-nya bounded.

Aturan penting:

- instrumentation disabled harus memiliki jalur langsung tanpa span/event;
- metrics dilarang memakai user ID, raw path, query, atau request ID sebagai
  label;
- sampling tracing harus diputuskan sebelum membangun atribut mahal;
- logging body/header sensitif bersifat opt-in dengan redaction;
- exporter network tidak boleh memblokir event loop;
- health/readiness bukan pengganti metrics dan tracing.

### 4.5 Production deployment

#### `WhiteThroatedTLS`

Tanggung jawab:

- konfigurasi HTTPS melalui adapter TLS yang terawat;
- certificate chain, private key, ALPN policy, dan minimum TLS version;
- reload/rotation strategy bila backend memungkinkan;
- explicit direct-TLS versus TLS termination di reverse proxy.

Core tetap dapat berjalan plain HTTP di belakang trusted reverse proxy. Scheme
dan secure-cookie decisions hanya boleh memakai forwarded headers melalui
`TrustedProxy` yang eksplisit.

#### `WhiteThroatedCompression`

Tanggung jawab:

- negosiasi `Accept-Encoding` yang benar;
- gzip terlebih dahulu; Brotli/Zstandard hanya melalui dependency/adapter yang
  dinilai terpisah;
- threshold, content-type allowlist, dan skip untuk body kecil/already-compressed;
- streaming compression dengan backpressure;
- `Vary: Accept-Encoding`, ETag/range/cache semantics yang benar;
- larangan compression pada response sensitif bila policy mitigasi side-channel
  mengharuskannya.

Prepared response boleh memiliki varian precompressed yang disiapkan saat setup.
Route tanpa compression tidak boleh membayar compressor allocation.

#### `WhiteThroatedLifecycle`

Tanggung jawab runtime-operasional:

- graceful shutdown dan drain timeout;
- readiness berubah sebelum listener dihentikan;
- cleanup service/database/exporter secara berurutan;
- signal handling yang dapat dinonaktifkan untuk embedding/test.

#### Deployment tooling

Ini bukan library request-path. Deliverable-nya meliputi:

- contoh release build dan container image;
- environment/secrets configuration guide;
- health/readiness endpoint recipe;
- graceful shutdown recipe;
- contoh reverse proxy dan direct TLS;
- template CI/CD dan Kubernetes/systemd bila sudah tervalidasi;
- checklist migration, rollout, rollback, dan observability.

Template deployment harus diberi status contoh, bukan jaminan aman untuk semua
infrastruktur. Jangan menambahkan source non-Swift untuk benchmark atau runtime
WhiteThroated; file deployment metadata harus tetap sesuai kebijakan repository.

### 4.6 Komunikasi/protokol tambahan

#### `WhiteThroatedCORS`

Tanggung jawab:

- simple request dan preflight;
- exact origin, bounded allowlist, dan dynamic origin resolver;
- method/header/exposed-header policy;
- credentials dan max-age;
- `Vary: Origin`/preflight cache semantics.

Wildcard origin tidak boleh digabung dengan credential secara tidak valid.
Rejection/pass-through behavior harus eksplisit dan diuji untuk route miss serta
middleware ordering.

#### `WhiteThroatedWebSocket`

Tanggung jawab:

- upgrade handshake dan subprotocol negotiation;
- frame/message API, fragmentation, ping/pong, close handshake;
- message and frame size limits;
- backpressure, cancellation, disconnect, dan exactly-once cleanup;
- optional compression sebagai capability terpisah.

Implementasi pertama sebaiknya memakai SwiftNIO WebSocket primitives melalui
stock NIO pipeline. Jangan memperluas Tier 1 parser sebelum semantik, tes
differential, lifecycle, dan benchmark stock path sudah matang. Aplikasi yang
mendaftarkan WebSocket boleh memilih pipeline pada setup-time; route non-
WebSocket tidak boleh melakukan upgrade bookkeeping bila capability tidak ada.

## 5. Dependency graph yang diusulkan

```text
WhiteThroated
  +-- StaticFiles
  +-- CORS
  +-- Validation <-- OpenAPI
  +-- Auth <-- Sessions <-- CSRF
  |      \------ Authorization policies
  +-- RateLimit <-- optional distributed-store adapter
  +-- Services
  +-- Database <-- ORM
  |            <-- Migrations CLI
  |            \-- Postgres adapter (system libpq)
  +-- Observability
  |      +-- Logging adapter
  |      +-- Metrics adapter
  |      \-- Tracing adapter
  +-- TLS
  +-- Compression
  +-- Lifecycle
  \-- WebSocket
```

Dependency antarmodul harus sesedikit mungkin. Secara khusus:

- semua dependency eksternal wajib mengikuti aturan Tier 1/fundamental pada
  bagian 3.6;
- Auth tidak bergantung wajib pada Sessions.
- Validation tidak bergantung pada OpenAPI.
- Observability tidak menjadi dependency wajib modul lain; modul lain hanya
  mengeluarkan event melalui hook opsional kecil.
- StaticFiles tidak bergantung pada Compression; keduanya berintegrasi melalui
  capability atau konfigurasi precompressed asset.
- WebSocket tidak bergantung pada Auth, tetapi upgrade route dapat memakai auth
  middleware yang sama.

## 6. Urutan implementasi

### Fase 0 — Kontrak dan package skeleton

Deliverable:

- catat baseline test/build/benchmark core;
- buat skeleton target/product terpisah di monorepo sesuai keputusan arsitektur;
- tetapkan naming, semantic version policy, dan dependency direction;
- buat integration test fixture yang dapat digunakan semua modul;
- definisikan aturan konfigurasi setup-time dan lifecycle shutdown;
- audit apakah hook core baru benar-benar diperlukan.

Exit gate:

- dependency graph tidak memiliki cycle;
- aplikasi tanpa modul menghasilkan behavior dan jalur dispatch yang sama;
- baseline core terdokumentasi sebelum hook apa pun ditambahkan.

### Fase 1 — Modul HTTP yang paling mandiri

Implementasikan berurutan:

1. `WhiteThroatedCORS`;
2. `WhiteThroatedStaticFiles`;
3. `WhiteThroatedValidation`;
4. `WhiteThroatedRateLimit` dengan in-memory store bounded.

Alasan: modul-modul ini menguji extension surface, middleware ordering,
filesystem I/O, lazy request access, serta provider contract tanpa terlebih dulu
mengunci desain identity atau database yang lebih luas.

### Fase 2 — Observability dan lifecycle

Implementasikan:

1. request ID dan structured logging;
2. bounded-cardinality HTTP metrics;
3. trace-context propagation dan tracing;
4. graceful shutdown/readiness melalui `WhiteThroatedLifecycle`.

Observability dibangun setelah extension surface terbukti, tetapi sebelum auth
dan database agar modul berikutnya dapat dioperasikan dan diukur sejak awal.

### Fase 3 — Identity dan state

Implementasikan:

1. auth principal + authentication middleware;
2. authorization policy;
3. memory session store untuk test/development;
4. satu production session adapter;
5. CSRF;
6. auth-related rate-limit integration.

Security review wajib sebelum menandai API production-ready.

### Fase 4 — Data dan services

Implementasikan:

1. typed service registry/lifecycle;
2. database pool/transaction contract;
3. satu adapter database sebagai proof of design;
4. migrations CLI;
5. ORM minimum setelah query dan transaction semantics stabil.

Jangan mendesain ORM terlebih dahulu lalu memaksa database contract mengikuti
ORM.

Status implementasi Fase 4 saat ini experimental: kontrak database, adapter
system libpq, migrations CLI, dan ORM minimum tersedia dengan coverage unit dan
integration test. Migrations masih forward-only; ORM belum memiliki relationship
atau lazy loading. Bukti dan batasan operasional dicatat di
`docs/data-services.md`.

### Fase 5 — Production HTTP

Implementasikan:

1. compression untuk buffered response;
2. compression untuk streaming dengan backpressure;
3. direct TLS configuration;
4. validated deployment examples dan operational checklist.

### Fase 6 — WebSocket dan OpenAPI completion

Implementasikan:

1. WebSocket stock-pipeline handshake dan lifecycle;
2. auth/observability integration untuk upgrade connection;
3. OpenAPI document generation;
4. shared validation/OpenAPI schema source;
5. hardening, fuzz/differential tests, dan API review lintas modul.

Fase ini tidak berarti kedua fitur saling bergantung; keduanya ditempatkan akhir
karena membutuhkan kontrak route/schema atau transport yang lebih matang.

## 7. Checklist desain untuk setiap modul

Setiap proposal modul harus menjawab:

1. Apa semantik publik dan error model-nya?
2. Apa yang terjadi saat modul tidak dipasang dan saat dipasang tetapi tidak
   digunakan oleh sebuah route?
3. Pekerjaan mana yang dilakukan saat setup, per connection, dan per request?
4. Apakah ada allocation, copy, ARC traffic, lock, `Task`, future, atau event-loop
   hop baru?
5. Bagaimana cancellation, shutdown, dan resource cleanup bekerja?
6. Data apa yang sensitif dan bagaimana redaction/default security-nya?
7. Apakah input/output tetap RFC-correct untuk `HEAD`, bodyless status,
   keep-alive, range, conditional request, dan streaming?
8. Apakah state bounded dan apa strategi eviction/backpressure-nya?
9. Backend/provider mana yang wajib dan mana yang opsional?
10. Bagaimana API diuji tanpa network dan kapan real network test diperlukan?
11. Benchmark apa yang membuktikan feature cost dan disabled-path neutrality?
12. Dokumentasi, migration guide, dan contoh minimal apa yang dibutuhkan?

## 8. Strategi testing

Setiap module target memiliki unit test dan integration test sendiri. Minimum:

- happy path, miss/pass-through, invalid input, boundary, dan cleanup;
- middleware ordering dan short-circuit;
- prepared, sync, future, dan async route compatibility bila relevan;
- stock dan Tier 1 transport equivalence kecuali capability memang memilih stock;
- keep-alive, pipelining, body limits, streaming, disconnect, dan write failure
  untuk fitur transport;
- deterministic clock/random/store injection untuk session, rate limit, dan auth;
- adversarial path/header/framing test untuk static files, CORS, CSRF, TLS, dan
  compression;
- compile-time API usage tests untuk overload dan type inference;
- full `swift test -c release` sebelum milestone selesai.

Security-sensitive parser/policy mendapat fuzz atau property test bila tooling
Swift yang dipilih dapat direproduksi di CI.

## 9. Strategi benchmark

Setiap fitur hot-path memiliki tiga kondisi:

1. modul tidak terpasang/disabled;
2. modul terpasang tetapi route tidak menggunakannya;
3. modul aktif pada route.

Acceptance utama:

- kondisi 1 tetap setara baseline core;
- kondisi 2 netral dalam noise atau overhead-nya terukur dan disetujui;
- kondisi 3 dibandingkan dengan control yang semantiknya identik;
- tidak ada klaim lebih cepat berdasarkan debug build atau satu run;
- p50/p90/p99/p99.999/max, errors, RPS, dan completed requests dicatat;
- peak RSS wajib untuk sessions, rate limits, static files, compression,
  WebSocket, database pool, dan exporter buffering;
- response throughput wajib untuk static files, compression, dan WebSocket;
- benchmark menggunakan release mode, warm-up, multiple rounds, dan urutan A/B
  bergantian sesuai `BENCHMARKS.md`.

Tambahkan matriks feature-specific secara opt-in agar benchmark route tidak
mengontaminasi baseline server.

## 10. Versioning dan release gates

Tahap maturity per modul:

```text
experimental -> preview -> stable
```

- **Experimental:** API dapat berubah; correctness coverage dasar tersedia.
- **Preview:** API review selesai, docs lengkap, integration adapter nyata,
  security review, dan benchmark record tersedia.
- **Stable:** compatibility policy, migration guide, CI platform matrix,
  production incident policy, dan maintenance owner jelas.

Sebuah modul tidak boleh dipromosikan hanya karena fiturnya dapat didemokan.
Gate preview/stable mencakup:

- release tests dan relevant products build;
- public API documentation dan contoh minimal;
- failure/cancellation/shutdown semantics;
- security checklist;
- disabled-path and enabled-path benchmark evidence;
- dependency/license review;
- tidak ada perubahan diam-diam pada semantik core.

## 11. Dokumentasi yang harus dihasilkan

Untuk setiap modul:

- README singkat dengan install dan minimal example;
- API reference dan concurrency/blocking notes;
- security defaults dan threat boundaries;
- operational guide dan observability fields;
- backend adapter matrix;
- benchmark methodology/result yang memisahkan fakta dari hipotesis;
- migration notes untuk breaking change.

Dokumentasi root WhiteThroated harus membedakan:

- fitur yang ada di core;
- modul resmi yang stabil;
- modul preview/experimental;
- integrasi komunitas/pihak ketiga.

## 12. Keputusan yang perlu dibuat sebelum implementasi

1. Versi platform minimum selain macOS dan target Linux CI untuk modul baru.
2. Dependency eksternal yang diizinkan untuk crypto, TLS, compression,
   observability, dan database. Keputusan: hanya Tier 1/fundamental sesuai
   bagian 3.6; paket framework/ecosystem seperti `vapor/*` dilarang. Adapter
   proof Fase 4 memakai system `libpq`, bukan paket driver framework lain.
3. Bentuk extension surface core: middleware saja, typed application storage,
   lifecycle hooks, atau kombinasi minimalnya.
4. Model konfigurasi environment/secrets dan ownership shutdown.
5. Modul pertama yang dijadikan vertical slice. Rekomendasi: CORS untuk
   middleware-only slice, lalu StaticFiles untuk I/O dan HTTP correctness.
6. Standar compatibility dan release cadence antar-package.

## 13. Estimasi token sampai siap produksi

Estimasi ini memakai **total model tokens**: input, output, konteks repository,
hasil tool/test/benchmark, review, dan iterasi perbaikan. Angka ini bukan ukuran
source code dan bukan jaminan biaya, durasi, atau kualitas. Token merupakan alat
perencanaan kasar; release gate tetap ditentukan oleh bukti correctness,
security, interoperability, dan benchmark.

Asumsi scope:

- implementasi dilakukan bertahap oleh coding agent dengan review manusia;
- macOS dan Linux menjadi platform utama;
- satu adapter database production dan satu adapter session/distributed store;
- gzip menjadi compression baseline;
- WebSocket dimulai dari stock SwiftNIO pipeline;
- crypto, TLS, database protocol, dan exporter tidak ditulis ulang sendiri;
- API dapat mengalami rework selama fase experimental/preview;
- estimasi mencakup test, documentation, benchmark, dan hardening;
- estimasi tidak mencakup banyak adapter vendor atau dukungan cloud platform
  yang luas.

### Anggaran per fase

| Fase | Scope utama | Estimasi token |
| --- | --- | ---: |
| 0 | Kontrak, package skeleton, baseline, extension surface | 0,5–0,9 juta |
| 1 | CORS, StaticFiles, Validation, RateLimit | 1,75–3,15 juta |
| 2 | Logging, metrics, tracing, lifecycle/shutdown | 1,3–2,35 juta |
| 3 | Authentication, authorization, sessions, CSRF, store adapter | 2,5–4,55 juta |
| 4 | Services, database contract/adapter, migrations, ORM | 3,7–6,65 juta |
| 5 | Compression, TLS, deployment tooling | 1,65–2,95 juta |
| 6 | WebSocket, OpenAPI, integration hardening | 2,8–5,0 juta |
| Lintas fase | Final audit, docs reconciliation, release fixes | 0,8–1,6 juta |
| **Subtotal engineering** |  | **15,0–27,15 juta** |
| **Cadangan rework 20–30%** | API churn, bug, benchmark regression | **3,0–8,15 juta** |
| **Working budget** | Sampai seluruh scope layak disebut production-ready | **18–35 juta** |

Gunakan **20–35 juta token** sebagai budget program yang realistis. Target
sekitar 18 juta hanya masuk akal bila kontrak cepat stabil, dependency yang
dipilih cocok, dan hasil test/benchmark tidak memerlukan redesign besar. Batas
atas dapat terlampaui jika ORM dibuat sangat luas, Tier 1 diperluas untuk
WebSocket, atau banyak backend resmi dimasukkan ke scope awal.

### Anggaran berdasarkan milestone produk

Tidak perlu menunggu seluruh katalog selesai untuk menghasilkan release yang
berguna:

| Milestone | Isi | Token kumulatif perkiraan |
| --- | --- | ---: |
| Modular foundation | Fase 0 | 0,5–0,9 juta |
| HTTP batteries preview | Fase 0–1 | 2,25–4,05 juta |
| Operable HTTP release | Fase 0–2 | 3,55–6,4 juta |
| Secure application preview | Fase 0–3 | 6,05–10,95 juta |
| Data-backed application preview | Fase 0–4 | 9,75–17,6 juta |
| Production HTTP candidate | Fase 0–5 | 11,4–20,55 juta |
| Full roadmap candidate | Fase 0–6 + final audit/rework | 18–35 juta |

Milestone tidak otomatis berarti production-ready. Setiap milestone masih harus
melewati release gate modul yang termasuk di dalamnya.

### Faktor yang paling banyak mengonsumsi token

- review lifecycle dan concurrency bugs yang hanya muncul saat disconnect,
  cancellation, pipelining, atau shutdown;
- adversarial security tests untuk auth, session, CSRF, path traversal, CORS,
  compression, dan proxy boundaries;
- ORM semantics, transaction behavior, migration locking, serta backend
  interoperability;
- benchmark before/after berulang dan diagnosis regression pada hot path;
- WebSocket framing, backpressure, close handshake, dan integration dengan auth;
- reconciliation dokumentasi/API setelah kontrak berubah.

### Biaya tambahan di luar baseline

Gunakan kisaran berikut untuk perubahan scope:

- adapter database production tambahan: 0,5–1,2 juta token per adapter;
- session/rate-limit store tambahan: 0,25–0,65 juta per adapter;
- JWT atau OIDC provider lengkap: 0,5–1,2 juta per provider;
- telemetry exporter tambahan: 0,25–0,6 juta per exporter;
- compression codec tambahan: 0,2–0,5 juta per codec;
- platform deployment tervalidasi: 0,25–0,75 juta per platform;
- dukungan WebSocket pada Tier 1 custom transport: 1,0–2,5 juta tambahan;
- template engine penuh, jika dimasukkan kembali ke scope: 1,0–2,5 juta.

### Pengendalian pemakaian token

- Kerjakan satu vertical slice sampai release gate sebelum membuka banyak modul.
- Gunakan proposal API singkat sebelum implementasi untuk mengurangi rework.
- Pertahankan konteks per modul; jangan memuat seluruh repository pada setiap
  iterasi.
- Jalankan targeted test selama iterasi dan full release suite pada milestone.
- Gunakan benchmark hanya ketika correctness sudah stabil.
- Catat keputusan arsitektur agar agent berikutnya tidak mengulang investigasi.
- Hentikan perluasan scope bila adapter kedua belum membuktikan kelemahan pada
  kontrak pertama.

Budget disarankan dialokasikan per milestone, bukan diberikan sekaligus. Setelah
setiap fase, bandingkan token aktual, jumlah rework, test failures, dan benchmark
regressions untuk memperbarui estimasi fase berikutnya.

## 14. Definisi selesai untuk roadmap modular

Roadmap dianggap terealisasi ketika:

- semua capability dapat dipilih tanpa umbrella dependency;
- aplikasi core-only tidak membayar feature bookkeeping yang tidak digunakan;
- dependency graph tetap satu arah dan runtime bebas konsep aplikasi;
- setiap modul memiliki correctness, security, lifecycle, dan benchmark gate;
- integration lintas auth/session/CSRF, validation/OpenAPI,
  static/compression, database/services, dan observability terbukti;
- deployment examples telah diuji pada environment yang didokumentasikan;
- README tidak menyebut WhiteThroated "batteries included" tanpa menjelaskan
  modul, status maturity, dan fitur yang benar-benar tersedia.
