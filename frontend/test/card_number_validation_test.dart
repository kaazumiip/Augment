import 'package:flutter_test/flutter_test.dart';
import '../lib/card_number_validation.dart';

void main() {
  test('Visa and Mastercard require brand, length and checksum', () {
    expect(isValidCardNumber('4111 1111 1111 1111'), isTrue);
    expect(isValidCardNumber('5555555555554444'), isTrue);
    expect(isValidCardNumber('2223003122003222'), isTrue);
    for (final number in [
      '4111111111111112',
      '0000000000000000',
      '378282246310005',
      '41111111111111',
      'hello4111111111111111'
    ]) {
      expect(isValidCardNumber(number), isFalse);
    }
  });
  test('Mastercard two-series boundaries are exact', () {
    expect(cardNumberBrand('2220'), 'CARD');
    expect(cardNumberBrand('2221'), 'mastercard');
    expect(cardNumberBrand('2720'), 'mastercard');
    expect(cardNumberBrand('2721'), 'CARD');
    expect(cardNumberBrand('55'), 'mastercard');
    expect(cardNumberBrand('56'), 'CARD');
  });
}
