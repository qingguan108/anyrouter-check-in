from unittest.mock import Mock

from checkin import get_user_info


def test_get_user_info_returns_balance_for_valid_json():
	response = Mock()
	response.status_code = 200
	response.json.return_value = {
		'success': True,
		'data': {'quota': 12_500_000, 'used_quota': 500_000},
	}
	client = Mock()
	client.get.return_value = response

	result = get_user_info(client, {}, 'https://example.com/api/user/self')

	assert result['success'] is True
	assert result['quota'] == 25.0
	assert result['used_quota'] == 1.0


def test_get_user_info_describes_non_json_response():
	response = Mock()
	response.status_code = 200
	response.json.side_effect = ValueError('not json')
	response.headers = {'content-type': 'text/html; charset=utf-8'}
	response.text = '<html>\n  <title>Access denied</title>\n</html>'
	response.content = response.text.encode()
	client = Mock()
	client.get.return_value = response

	result = get_user_info(client, {}, 'https://example.com/api/user/self')

	assert result['success'] is False
	assert 'HTTP 200 returned non-JSON' in result['error']
	assert 'content-type=text/html; charset=utf-8' in result['error']
	assert "preview='<html> <title>Access denied</title> </html>'" in result['error']
