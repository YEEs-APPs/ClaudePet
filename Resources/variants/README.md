# 아이콘 시안 / Icon variants

기본으로 쓰이는 것은 `Resources/AppIcon.icns`(= C)와 `Resources/MenuBarIcon*.png`(= M1)입니다.
다른 시안으로 바꾸려면 파일만 덮어쓰면 됩니다. 코드는 바꿀 것이 없습니다.

The defaults are `Resources/AppIcon.icns` (= C) and `Resources/MenuBarIcon*.png` (= M1).
To switch, just overwrite the files. No code change is needed.

```bash
# 예: 앱 아이콘 B, 메뉴바 M2 / e.g. app icon B, menu bar M2
cp Resources/variants/AppIcon-B.icns Resources/AppIcon.icns
cp Resources/variants/MenuBarIcon-M2.png Resources/MenuBarIcon.png
cp "Resources/variants/MenuBarIcon-M2@2x.png" "Resources/MenuBarIcon@2x.png"
```

| 파일 / File | 설명 / Description |
|---|---|
| `AppIcon-A` | 남색 바탕, 펫 작게 / navy plate, small pet |
| `AppIcon-B` | 남색 바탕, 펫 크게 / navy plate, larger pet |
| `AppIcon-C` | 크림색 바탕 / cream plate |
| `MenuBarIcon-M1` | 통으로 채운 실루엣 / solid silhouette |
| `MenuBarIcon-M2` | 눈 자리를 뚫음 / eyes cut out |
| `MenuBarIcon-M3` | 눈을 뚫고 동공만 채움 / eyes cut out, pupils filled |

모두 `tools/make-icons` 로 만들었습니다. / All of them come from `tools/make-icons`.

미리보기 / Previews: `preview.png` (A·B·C), `preview-menubar.png` (M1·M2·M3)
