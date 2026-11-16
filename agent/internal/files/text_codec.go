package files

import (
	"bytes"
	"errors"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/japanese"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
	"golang.org/x/text/encoding/unicode"
	"golang.org/x/text/transform"
)

func textEncoding(name string) (encoding.Encoding, []byte, error) {
	switch name {
	case "utf-8", "":
		return nil, nil, nil
	case "utf-8-bom":
		return nil, []byte{0xef, 0xbb, 0xbf}, nil
	case "utf-16le":
		return unicode.UTF16(unicode.LittleEndian, unicode.IgnoreBOM), nil, nil
	case "utf-16le-bom":
		return unicode.UTF16(unicode.LittleEndian, unicode.IgnoreBOM), []byte{0xff, 0xfe}, nil
	case "utf-16be":
		return unicode.UTF16(unicode.BigEndian, unicode.IgnoreBOM), nil, nil
	case "utf-16be-bom":
		return unicode.UTF16(unicode.BigEndian, unicode.IgnoreBOM), []byte{0xfe, 0xff}, nil
	case "gb18030":
		return simplifiedchinese.GB18030, nil, nil
	case "big5":
		return traditionalchinese.Big5, nil, nil
	case "shift-jis":
		return japanese.ShiftJIS, nil, nil
	case "windows-1252":
		return charmap.Windows1252, nil, nil
	default:
		return nil, nil, errors.New("不支持的文本编码")
	}
}

func detectTextEncoding(data []byte, selected string) string {
	if selected != "" && selected != "auto" {
		return selected
	}
	switch {
	case bytes.HasPrefix(data, []byte{0xef, 0xbb, 0xbf}):
		return "utf-8-bom"
	case bytes.HasPrefix(data, []byte{0xff, 0xfe}):
		return "utf-16le-bom"
	case bytes.HasPrefix(data, []byte{0xfe, 0xff}):
		return "utf-16be-bom"
	default:
		return "utf-8"
	}
}

func encodeText(text []byte, name string) ([]byte, error) {
	if !utf8.Valid(text) {
		return nil, errors.New("输入不是有效 UTF-8 文本")
	}
	codec, bom, err := textEncoding(name)
	if err != nil {
		return nil, err
	}
	out := text
	if codec != nil {
		out, _, err = transform.Bytes(codec.NewEncoder(), text)
		if err != nil {
			return nil, errors.New("所选编码无法表示这些字符，未保存文件")
		}
	}
	if len(bom) > 0 {
		out = append(append([]byte(nil), bom...), out...)
	}
	return out, nil
}

func decodeText(data []byte, name string) ([]byte, error) {
	codec, bom, err := textEncoding(name)
	if err != nil {
		return nil, err
	}
	body := data
	if len(bom) > 0 {
		if !bytes.HasPrefix(body, bom) {
			return nil, errors.New("文件缺少所选编码的 BOM")
		}
		body = body[len(bom):]
	}
	out := body
	if codec != nil {
		out, _, err = transform.Bytes(codec.NewDecoder(), body)
		if err != nil {
			return nil, err
		}
	}
	if !utf8.Valid(out) || strings.ContainsRune(string(out), 0) {
		return nil, errors.New("文件不是所选编码的文本")
	}
	// Several legacy decoders substitute invalid sequences silently. Require a
	// byte-exact round trip before offering an editable document.
	roundtrip, err := encodeText(out, name)
	if err != nil || !bytes.Equal(roundtrip, data) {
		return nil, errors.New("所选编码不能无损解码文件")
	}
	return out, nil
}
