/// Card-number format checks only; bank authorization requires a gateway.
String cardNumberBrand(String input) {
  final digits = input.replaceAll(RegExp(r'[ -]'), '');
  if (!RegExp(r'^\d+$').hasMatch(digits)) return 'CARD';
  if (digits.startsWith('4')) return 'VISA';
  if (digits.length >= 2) {
    final prefix = int.parse(digits.substring(0, 2));
    if (prefix >= 51 && prefix <= 55) return 'mastercard';
  }
  if (digits.length >= 4) {
    final prefix = int.parse(digits.substring(0, 4));
    if (prefix >= 2221 && prefix <= 2720) return 'mastercard';
  }
  return 'CARD';
}

bool isValidCardNumber(String input) {
  final digits = input.replaceAll(RegExp(r'[ -]'), '');
  final brand = cardNumberBrand(input);
  if (brand == 'VISA') {
    if (![13, 16, 19].contains(digits.length)) return false;
  } else if (brand == 'mastercard') {
    if (digits.length != 16) return false;
  } else {
    return false;
  }
  var sum = 0;
  for (var index = 0; index < digits.length; index++) {
    var value = int.parse(digits[digits.length - 1 - index]);
    if (index.isOdd) {
      value *= 2;
      if (value > 9) value -= 9;
    }
    sum += value;
  }
  return sum % 10 == 0;
}
