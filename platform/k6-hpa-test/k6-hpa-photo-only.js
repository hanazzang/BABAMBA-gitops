import http from "k6/http";
import { check, sleep } from "k6";
import encoding from "k6/encoding";

/**
 * Photo-only 시나리오(컴포넌트 단독 부하)
 * - 로그인/employee와 분리해서 photo 서비스(또는 gateway의 /photo 경로)만 단독으로 때립니다.
 * - 기본은 gateway 경로(/photo/)로 보내서 라우팅/프록시 + photo 서비스까지 포함한 "photo 경로" 용량을 봅니다.
 *   완전한 photo 서비스 단독을 원하면 PHOTO_URL을 photo 서비스 ClusterIP로 바꿔서 실행하세요.
 *
 * 실무 포인트:
 * - Photo는 보통 GET(조회)보다 WRITE(업로드/변환/저장) 비용이 크므로 WRITES_PER_SEC 기반 "write-only" 템플릿도 제공합니다.
 * - 단, photo 서비스의 업로드 API 경로/폼필드명은 프로젝트마다 다를 수 있어 ENV로 쉽게 바꿀 수 있게 해둡니다.
 */

const users = Number(__ENV.USERS || 100);
const duration = __ENV.DURATION || "5m";
const timeout = __ENV.TIMEOUT || "10s";

// 사용자당 초당 GET/WRITE 기대치(소수 가능).
const getsPerSec = Number(__ENV.GETS_PER_SEC || 2);
const writesPerSec = Number(__ENV.WRITES_PER_SEC || 0);

// 기본: gateway의 /photo/ (HTTPRoute가 /photo/ prefix를 매칭/리라이트)
const photoBase =
  __ENV.PHOTO_URL || "http://service-gateway.gateway.svc.cluster.local/photo/";

const host = __ENV.HOST_HEADER || "";

// 기본 경로들(필요 시 override)
// - gateway:   /photo/<path>  -> (rewrite) /<path>
// - clusterIP: /<path>
const getPath = String(__ENV.PHOTO_GET_PATH || "health");
const writePath = String(__ENV.PHOTO_WRITE_PATH || "upload");

function joinUrl(base, path) {
  const b = base.endsWith("/") ? base : `${base}/`;
  const p = path.startsWith("/") ? path.slice(1) : path;
  return `${b}${p}`;
}

const photoGetUrl = __ENV.PHOTO_GET_URL || joinUrl(photoBase, getPath);
const photoWriteUrl = __ENV.PHOTO_WRITE_URL || joinUrl(photoBase, writePath);

// write payload: tiny PNG
const fileField = __ENV.PHOTO_FILE_FIELD || "file"; // 프로젝트에 따라 "photo"/"file" 등으로 다를 수 있음
const tinyPngB64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6Xn2gAAAABJRU5ErkJggg==";
const tinyPngBytes = encoding.b64decode(tinyPngB64, "std");

export const options = {
  scenarios: {
    photo_only: {
      executor: "constant-vus",
      vus: users,
      duration,
    },
  },
};

function headers() {
  const h = {};
  if (host) h["Host"] = host;
  return h;
}

function sampleCount(ratePerSec) {
  if (!isFinite(ratePerSec) || ratePerSec <= 0) return 0;
  const base = Math.floor(ratePerSec);
  const frac = ratePerSec - base;
  return base + (Math.random() < frac ? 1 : 0);
}

export default function () {
  while (true) {
    const start = Date.now();

    const w = sampleCount(writesPerSec);
    for (let i = 0; i < w; i++) {
      // k6는 object payload + http.file(...) 사용 시 multipart/form-data를 자동 구성합니다.
      const payload = {
        [fileField]: http.file(tinyPngBytes, "photo.png", "image/png"),
      };
      const res = http.post(photoWriteUrl, payload, { timeout, headers: headers() });
      check(res, { "photo WRITE status is 2xx": (r) => r.status >= 200 && r.status < 300 });
    }

    const n = sampleCount(getsPerSec);
    for (let i = 0; i < n; i++) {
      const res = http.get(photoGetUrl, { timeout, headers: headers() });
      check(res, { "photo GET status is 2xx": (r) => r.status >= 200 && r.status < 300 });
    }

    const elapsed = (Date.now() - start) / 1000;
    sleep(Math.max(0, 1 - elapsed));
  }
}

