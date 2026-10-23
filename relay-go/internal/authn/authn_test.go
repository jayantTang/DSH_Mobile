package authn

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

// TestBearerToken 覆盖头的三种形态：正常、大小写、缺失/坏格式。
func TestBearerToken(t *testing.T) {
	cases := []struct {
		name   string
		header string
		want   string
	}{
		{"正常", "Bearer as_secret", "as_secret"},
		{"大小写不敏感", "bearer as_secret", "as_secret"},
		{"前后空白", "Bearer   as_secret  ", "as_secret"},
		{"缺头", "", ""},
		{"别的方案", "Basic as_secret", ""},
		{"只有方案", "Bearer", ""},
		{"空令牌", "Bearer   ", ""},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/", nil)
			if testCase.header != "" {
				request.Header.Set("Authorization", testCase.header)
			}
			if got := BearerToken(request); got != testCase.want {
				t.Fatalf("BearerToken = %q，期望 %q", got, testCase.want)
			}
		})
	}
}

// TestDeviceSubprotocolToken：只认 dsh.device. 前缀的第一枚非空令牌。
func TestDeviceSubprotocolToken(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Sec-WebSocket-Protocol",
		"chat, dsh.device.dt_first , dsh.device.dt_second")
	if got := DeviceSubprotocolToken(request); got != "dt_first" {
		t.Fatalf("DeviceSubprotocolToken = %q", got)
	}

	empty := httptest.NewRequest(http.MethodGet, "/", nil)
	empty.Header.Set("Sec-WebSocket-Protocol", "dsh.device., chat")
	if got := DeviceSubprotocolToken(empty); got != "" {
		t.Fatalf("空前缀后缀应返回空串，实际 %q", got)
	}

	missing := httptest.NewRequest(http.MethodGet, "/", nil)
	if got := DeviceSubprotocolToken(missing); got != "" {
		t.Fatalf("没有头时应返回空串，实际 %q", got)
	}
}

// TestDeviceProtocolsOffered：回显的是客户端提出的全部 dsh.device.* 子协议。
func TestDeviceProtocolsOffered(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Sec-WebSocket-Protocol", "chat,dsh.device.a,dsh.device.b")
	got := DeviceProtocolsOffered(request)
	want := []string{"dsh.device.a", "dsh.device.b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("DeviceProtocolsOffered = %v，期望 %v", got, want)
	}
	if got := DeviceProtocolsOffered(httptest.NewRequest(http.MethodGet, "/", nil)); len(got) != 0 {
		t.Fatalf("没有头时应为空：%v", got)
	}
}
