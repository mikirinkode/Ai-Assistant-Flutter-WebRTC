import 'dart:convert';
import 'package:http/http.dart' as http;

class OpenAIService {
  static const String baseUrl = 'https://api.openai.com/v1';
  static const String apiKey = '';

  static Future<String> getEphemeralToken() async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/realtime/sessions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'gpt-4o-realtime-preview-2024-12-17',
          'voice': 'verse',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['client_secret']['value'];
      } else {
        throw Exception(
            'Failed to get ephemeral token: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error getting ephemeral token: $e');
    }
  }
}
