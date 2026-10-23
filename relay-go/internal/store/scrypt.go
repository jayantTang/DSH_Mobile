package store

import "golang.org/x/crypto/scrypt"

// scryptKey 按 Python 版 store.py 的参数派生配对码哈希。
//
// n=1<<14, r=8, p=1, dklen=32；参数写死在一处，测试用已知盐与 Python 交叉验证。
func scryptKey(password, salt []byte) ([]byte, error) {
	return scrypt.Key(password, salt, scryptN, scryptR, scryptP, scryptKeyLen)
}
