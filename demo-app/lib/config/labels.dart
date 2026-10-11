import 'package:flutter/material.dart';

/// 계약 enum ↔ 화면 표시 문자열. 값(키)은 `backend/docs/openapi.yaml`과 같아야 한다.

/// 유저플로우 6종(2026-10-09 결정).
const garmentCategories = <String, String>{
  'outerwear': '아우터',
  'top': '상의',
  'bottom': '하의',
  'shoes': '신발',
  'bag': '가방',
  'accessory': '액세서리',
};

String categoryLabel(String? code) => code == null ? '미분류' : garmentCategories[code] ?? code;

/// 피드 날씨 필터(유저플로우: 맑음·흐림·비·눈·바람).
const weatherCodes = <String, String>{
  'clear': '맑음',
  'cloudy': '흐림',
  'rain': '비',
  'snow': '눈',
  'wind': '바람',
};

String weatherLabel(String? code) => weatherCodes[code] ?? '날씨 정보 없음';

IconData weatherIcon(String? code) => switch (code) {
      'clear' => Icons.wb_sunny_outlined,
      'cloudy' => Icons.cloud_outlined,
      'rain' => Icons.umbrella_outlined,
      'snow' => Icons.ac_unit,
      'wind' => Icons.air,
      _ => Icons.help_outline,
    };

const precipitationLabels = <String, String>{
  'none': '강수 없음',
  'rain': '비',
  'snow': '눈',
  'mixed': '비/눈',
  'unknown': '알 수 없음',
};

/// 위치 권한 거절 시 직접 고르는 시·도 17개(`RegionCode`).
const regions = <String, String>{
  'seoul': '서울특별시',
  'busan': '부산광역시',
  'daegu': '대구광역시',
  'incheon': '인천광역시',
  'gwangju': '광주광역시',
  'daejeon': '대전광역시',
  'ulsan': '울산광역시',
  'sejong': '세종특별자치시',
  'gyeonggi': '경기도',
  'gangwon': '강원특별자치도',
  'chungbuk': '충청북도',
  'chungnam': '충청남도',
  'jeonbuk': '전북특별자치도',
  'jeonnam': '전라남도',
  'gyeongbuk': '경상북도',
  'gyeongnam': '경상남도',
  'jeju': '제주특별자치도',
};

/// 추천 shortfall 사유 → 사용자 문구.
String shortfallText(String reason) {
  if (reason == 'insufficient_wardrobe') return '옷장을 채우면 추천을 받을 수 있어요 (2벌 이상 필요)';
  if (reason == 'requested_count_not_reached') return '지금 옷장으로는 3개를 다 만들지 못했어요';
  if (reason.startsWith('missing_category:')) {
    return '${categoryLabel(reason.substring('missing_category:'.length))}이(가) 없어 조합이 제한돼요';
  }
  return reason;
}

const mimicGradeLabels = <String, String>{'high': '높음', 'medium': '보통', 'low': '낮음'};

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
