# RinKeys

Xem toàn bộ phím tắt của app bạn đang dùng trên Mac. Bấm icon ⌘ trên thanh menu (hoặc nhấn ⌘ hai lần rồi giữ) là hiện bảng kính với mọi phím tắt của app đó, tìm nhanh, bấm để chạy lệnh và lưu bảng thành ảnh.

Miễn phí, mã nguồn mở (MIT). Làm bởi [Phước Rin](https://youtube.com/@phuocrin).

[English below](#english)

## Tính năng

- Đọc phím tắt trên thanh menu của **mọi app** (Safari, Final Cut Pro, Photoshop, Finder, Xcode…), mỗi menu là một thẻ riêng.
- **Dịch tên lệnh** của app không có tiếng Việt (Final Cut Pro, Photoshop…) bằng bộ dịch có sẵn của macOS, dịch ngay trên máy, tên gốc nằm dòng dưới. Final Cut Pro giữ nguyên các thuật ngữ người dựng hay dùng (Audition, Storyline, Compound Clip, Blade…). Cần macOS 15 trở lên.
- **Tìm** theo tên lệnh hoặc theo phím (gõ `⌘K`). Enter chạy kết quả đầu tiên.
- **Bấm một dòng để chạy lệnh** đó trong app.
- **Nhấn ⌘ hai lần rồi giữ** để xem nhanh, thả ra là ẩn. Đưa chuột vào bảng trước khi thả để giữ bảng lại.
- **Ghim** để bảng luôn mở và tự đổi theo app bạn chuyển sang.
- **Lưu thành ảnh** (PNG, kiểu kính mờ) để chia sẻ. Đang tìm thì ảnh chỉ có kết quả tìm, đang dịch thì ảnh có cả tên tiếng Việt.
- **Final Cut Pro** và **Photoshop** có thêm nhóm phím mặc định không nằm trên thanh menu (J / K / L, phím công cụ V, B, M…).
- Tuỳ chọn hiện icon trên Dock: bấm icon là xem phím tắt của app vừa dùng.
- Tự kiểm tra bản mới, cập nhật trong app (gói cập nhật có chữ ký).

## Cài đặt

1. Tải `RinKeys.dmg` ở [Releases](https://github.com/PhuocRin/RinKeys/releases/latest).
2. Mở file, kéo **RinKeys** vào **Applications**.
3. Mở RinKeys. Nếu macOS chặn: bấm **Xong** (đừng bấm Chuyển vào Thùng rác) → **Cài đặt hệ thống → Quyền riêng tư & Bảo mật** → kéo xuống phần Bảo mật → **Vẫn mở**.
4. Cấp quyền **Trợ năng**: Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → bật **RinKeys**.

Cần macOS 14 trở lên, chạy trên Mac chip Apple và Mac Intel.

## Quyền và quyền riêng tư

RinKeys cần quyền **Trợ năng (Accessibility)** để đọc thanh menu của app đang dùng và bấm lệnh giúp bạn. RinKeys chỉ để ý phím ⌘ để mở bảng xem nhanh, không ghi lại phím bạn gõ, không gửi gì ra ngoài. Bản dịch làm bằng bộ dịch của macOS ngay trên máy (lần đầu macOS có thể hỏi tải gói ngôn ngữ). Kết nối mạng duy nhất của RinKeys là hỏi GitHub có bản mới không.

## Giới hạn

- Chỉ đọc được phím tắt nằm trên thanh menu. Phím chỉ có trong cài đặt riêng của app thì không đọc được (trừ nhóm phím mặc định của Final Cut Pro và Photoshop).
- Một số app tự vẽ menu riêng (một số game, app viết bằng công cụ không chuẩn) thì macOS không cho đọc.
- Nhóm phím mặc định của Final Cut Pro và Photoshop là phím gốc của hãng. Nếu bạn đã đổi phím trong app thì có thể khác.

## Build từ mã nguồn

```
./build.sh dmg
```

Cần Xcode (Swift 6) trên macOS 14+. Mỗi lần đẩy code lên `main`, GitHub Actions tự build và để file `.dmg` ở mục Artifacts.

## Ủng hộ tác giả

RinKeys miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin ngay trong app (♥ Ủng hộ tác giả) hoặc qua [PayPal](https://paypal.me/phuocrin).

---

## English

RinKeys shows every keyboard shortcut of the app you're using on your Mac. Click the ⌘ icon in the menu bar (or double-press and hold ⌘) to get a glass sheet with all of that app's shortcuts. Search them, click one to run it, and save the sheet as an image.

Free and open source (MIT). Made by [Phước Rin](https://youtube.com/@phuocrin).

**Features:** reads menu-bar shortcuts of any app, one card per menu · translates command names of apps that aren't in your language with macOS's on-device translator (macOS 15+), keeping Final Cut Pro terms like Audition or Storyline · search by name or by keys (type `⌘K`), Enter runs the first result · click a row to run the command · double-press and hold ⌘ to peek, release to hide (move the mouse onto the sheet first to keep it) · pin the sheet so it follows the app you switch to · save the sheet as a PNG · extra default-key groups for Final Cut Pro and Photoshop that aren't in the menu bar · optional Dock icon · built-in signed updates.

**Install:** download `RinKeys.dmg` from [Releases](https://github.com/PhuocRin/RinKeys/releases/latest), drag RinKeys to Applications and open it. If macOS blocks it, click Done (not Move to Trash), then System Settings → Privacy & Security → Security → Open Anyway. Then allow **Accessibility**: System Settings → Privacy & Security → Accessibility → turn on RinKeys. Requires macOS 14 or later.

**Privacy:** Accessibility access is used to read the current app's menu bar and run commands you click. RinKeys only watches the ⌘ key for the peek gesture; it doesn't record what you type or send anything anywhere. The only network request is checking GitHub for new versions.

**Limits:** only shortcuts that appear in the menu bar can be read (plus the default-key groups for Final Cut Pro and Photoshop). Apps that draw their own menus can't be read. Default keys may differ if you've changed them in the app.

**Support:** RinKeys is free. If it helps you, you can support Phước Rin in the app (♥ Support the Author) or via [PayPal](https://paypal.me/phuocrin).
