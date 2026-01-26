import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  vus: 10,
  duration: '30s',
};

export default function () {
  // 서비스 주소는 내부 k8s 서비스 도메인 사용
  const res = http.get('http://photo-service.photo.svc.cluster.local:5003/photo');
  
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
  
  sleep(1);
}