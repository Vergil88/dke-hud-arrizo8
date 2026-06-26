/// UDS Negative Response Codes — 对应 Python 中的 NRC_MAP
class NrcCodes {
  static const Map<int, String> map = {
    0x10: 'generalReject',
    0x11: 'serviceNotSupported',
    0x12: 'subFuncNotSupported',
    0x13: 'incorrectMsgLen',
    0x22: 'conditionsNotCorrect',
    0x31: 'requestOutOfRange',
    0x33: 'securityAccessDenied',
    0x78: 'responsePending',
    0x7E: 'subFuncNotSupportedInSession',
    0x7F: 'serviceNotSupportedInSession',
  };

  static String describe(int code) =>
      map[code] ?? 'unknown(0x${code.toRadixString(16).padLeft(2, '0')})';
}
