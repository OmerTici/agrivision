import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

/// In-app language switching. Views observe the shared instance and re-render
/// when the language changes; the choice persists across launches.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    private static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    func t(_ key: String) -> String {
        Self.tables[language]?[key] ?? Self.tables[.english]?[key] ?? key
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = language.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: language.locale)
        )
    }

    private static let tables: [AppLanguage: [String: String]] = [
        .english: [
            // Home
            "greeting.morning": "Good morning",
            "greeting.afternoon": "Good afternoon",
            "greeting.evening": "Good evening",
            "home.animals": "Animals",
            "home.avgWeight": "Avg Weight",
            "home.scansThisWeek": "Scans This Week",
            "home.muzzleIDs": "Muzzle IDs",
            "home.weightTrend": "Herd Weight Trend",
            "home.recentScans": "Recent Scans",
            "home.seeAll": "See All",
            "home.recentActions": "Recent Actions",
            "home.noEvents": "No activity yet — enroll or identify an animal to see it here.",
            "home.needsScan": "Needs Scanning",

            // Tab bar
            "tab.home": "home",
            "tab.animals": "animals",
            "tab.add": "add",
            "tab.settings": "settings",

            // Statuses & results
            "status.healthy": "Healthy",
            "status.pregnant": "Pregnant",
            "status.attention": "Needs Attention",
            "scan.identified": "Identified",
            "scan.newID": "New ID",
            "scan.noMatch": "No Match",
            "sex.female": "Female",
            "sex.male": "Male",

            // Events (recent actions feed)
            "event.enrolled": "%@ — enrolled",
            "event.identified": "%@ — identified (%.2f)",
            "event.identifiedNoScore": "%@ — identified",
            "event.noMatch": "Unknown animal — no match",
            "event.unknownAnimal": "Unknown animal",
            "common.retry": "Retry",
            "common.close": "Close",
            "common.loadError": "Couldn't load your data.",

            // Animals
            "animals.title": "My Herd",
            "animals.subtitle": "%d animals · %d muzzle IDs registered",
            "animals.search": "Search by name, tag or breed",
            "filter.all": "All",
            "filter.females": "Females",
            "filter.males": "Males",
            "animals.empty": "No animals found",
            "animals.emptyHerd": "No animals yet — tap + to add your first.",
            "animals.lastScan": "Last scan",
            "animals.never": "Never scanned",
            "unit.yr": "yr",
            "unit.mo": "mo",
            "detail.title": "Animal Profile",
            "detail.muzzleID": "Muzzle ID",
            "detail.notRegistered": "Not Registered",
            "detail.enrolled": "Enrolled",
            "detail.breed": "Breed",
            "detail.sex": "Sex",
            "detail.age": "Age",
            "detail.currentWeight": "Current Weight",
            "detail.lastScan": "Last Scan",
            "detail.weightHistory": "Weight History",
            "detail.weighIns": "Weigh-ins",
            "detail.notEnough": "Not enough weigh-ins to chart yet.",

            // Add animal
            "add.title": "Add Animal",
            "add.subtitle": "Register a new animal to your herd",
            "add.scanPrompt": "Scan muzzle to register ID",
            "add.scanDone": "Muzzle ID captured",
            "add.scanHint": "Point the camera at the animal's nose — its muzzle print is as unique as a fingerprint",
            "add.scanHintDone": "Unique muzzle pattern stored for this animal",
            "add.name": "Name",
            "add.namePh": "e.g. Daisy",
            "add.tag": "Tag Number",
            "add.tagPh": "e.g. TR-0412",
            "add.breed": "Breed",
            "add.dob": "Date of Birth",
            "add.weight": "Current Weight (optional)",
            "add.weightPh": "e.g. 420",
            "add.save": "Save Animal",
            "add.saved": "Animal added to herd",
            "edit.title": "Edit Animal",
            "edit.subtitle": "Update this animal's details",
            "edit.save": "Save Changes",
            "detail.edit": "Edit",
            "detail.delete": "Delete Animal",
            "delete.confirmTitle": "Delete this animal?",
            "delete.confirmBody": "It will be archived and removed from your herd. You can undo this right after.",
            "delete.confirm": "Delete",
            "common.cancel": "Cancel",
            "undo.archived": "Animal archived",
            "undo.action": "Undo",

            // Settings
            "settings.title": "Settings",
            "settings.account": "Account",
            "settings.changeEmail": "Change Email",
            "settings.changePassword": "Change Password",
            "settings.currentEmail": "Current email",
            "settings.newEmail": "New email",
            "settings.verificationCode": "Verification code",
            "settings.verificationCodePh": "6-digit code from email",
            "settings.sendCode": "Send code to email",
            "settings.resendCode": "Resend code",
            "settings.codeSent": "We emailed you a 6-digit code. Enter it below to confirm.",
            "settings.newPassword": "New password",
            "settings.confirmNewPassword": "Confirm new password",
            "settings.newPasswordPh": "Enter a new password",
            "settings.save": "Save",
            "settings.saving": "Saving…",
            "settings.emailUpdated": "Check your new email to confirm the change.",
            "settings.passwordUpdated": "Your password has been updated.",
            "settings.language": "Language",
            "settings.preferences": "Preferences",
            "settings.notifications": "Notifications",
            "settings.autoCapture": "Auto-Capture on Detection",
            "settings.metric": "Metric Units (kg)",
            "settings.about": "About",
            "settings.help": "Help & Support",
            "settings.privacy": "Privacy Policy",
            "settings.version": "Version",
            "settings.signout": "Sign Out",

            // Camera
            "camera.mode.automatic": "Automatic",
            "camera.mode.manual": "Manual",
            "camera.hint.point": "Point at the cow's head.",
            "camera.hint.hold": "Head detected — hold steady…",
            "camera.hint.tap": "Head ready — tap to capture.",
            "camera.analyzing": "Analyzing photo…",
            "camera.help": "Help?",
            "camera.success.title": "Muzzle captured!",
            "camera.success.msg": "The muzzle was detected and cropped successfully.",
            "camera.failed.title": "Scan failed",
            "camera.fail.read": "Could not read the photo. Try again.",
            "camera.fail.crop": "Muzzle could not be detected or cropped. Try again.",
            "camera.viewResult": "View result",
            "camera.scanAgain": "Scan again",
            "camera.denied.title": "Camera access needed",
            "camera.denied.msg": "Allow camera access in Settings to scan animals.",
            "camera.openSettings": "Open Settings",
            "camera.guide.title": "Scanning guide",
            "camera.guide.body": "Place the animal inside the white square on your screen. It does not need to be perfect — as long as it stays within the frame, the scan should work.",
            "camera.guide.correct": "Correct",
            "camera.guide.wrong": "Wrong",
            "camera.guide.tip1": "Move closer or farther until the subject fits comfortably inside the square.",
            "camera.guide.tip2": "Find good lighting and hold your phone steady before taking the photo.",
            "camera.guide.tip3": "Keep the subject fully inside the frame — avoid cutting it off at the edges.",
            "camera.understand": "I understand",
            "camera.result.title": "Detection result",
            "camera.result.cropped": "Cropped muzzle",
            "camera.result.full": "Full photo",
            "camera.result.noCrop": "No muzzle crop was produced.",
            "camera.result.noPhoto": "No photo available.",
            "camera.done": "Done",
            "camera.enroll.progress": "Muzzle %d of %d",
            "camera.enroll.submitting": "Enrolling…",
            "camera.enroll.success": "Animal enrolled",
            "camera.enroll.failed": "Enrollment failed",
            "camera.enroll.retry": "Retry enrollment",
            "camera.identify.identified": "Identified",
            "camera.identify.unknown": "Animal not recognized",
            "camera.identify.score": "Confidence %.0f%%",
            "camera.identify.enroll": "Enroll this animal",
            "camera.identify.waking": "Waking up recognizer…",
            "camera.identify.offline": "Network unavailable. Try again.",
            "camera.identify.retry": "Try again",
            "server.status.connecting": "Connecting…",
            "server.status.offline": "Server offline — tap to retry",

            // Recognition errors
            "recognition.error.notAuthenticated": "Not signed in.",
            "recognition.error.http": "Server error (%d).",
            "recognition.error.network": "Network unavailable.",
            "recognition.error.encoding": "Could not prepare the image.",
            "recognition.error.decoding": "Unexpected server response.",

            // Auth
            "auth.landing.subtitle": "Choose how you'd like to continue",
            "auth.signin": "Sign In",
            "auth.signup": "Sign Up",
            "auth.login.subtitle": "Welcome back. Sign in to continue.",
            "auth.method.email": "Email",
            "auth.method.phone": "Phone",
            "auth.email": "Email",
            "auth.emailPh": "you@example.com",
            "auth.phone": "Phone number",
            "auth.password": "Password",
            "auth.passwordPh": "Enter your password",
            "auth.forgot": "Forgot Password?",
            "auth.login": "Log in",
            "auth.noAccount": "Don't have an account?",
            "auth.signupAction": "Sign up",
            "auth.create": "Create Account",
            "auth.fullName": "Full name",
            "auth.fullNamePh": "Your name",
            "auth.createPw": "Create a password",
            "auth.confirmPw": "Confirm password",
            "auth.repeatPw": "Repeat your password",
            "auth.haveAccount": "Already have an account?",
            "auth.forgotTitle": "Forgot Password",
            "auth.forgotSubtitle": "Enter your email or phone number and we'll send you a reset link.",
            "auth.sendReset": "Send Reset Link",
            "auth.remember": "Remember your password?",
            "auth.backToLogin": "Back to login",
            "auth.error.generic": "Something went wrong. Please try again.",
            "auth.signingIn": "Signing in…",
            "auth.signingUp": "Creating account…",
            "auth.mismatch": "Passwords do not match.",
            "auth.confirmEmail": "Check your email to confirm your account.",
        ],
        .turkish: [
            // Home
            "greeting.morning": "Günaydın",
            "greeting.afternoon": "İyi günler",
            "greeting.evening": "İyi akşamlar",
            "home.animals": "Hayvanlar",
            "home.avgWeight": "Ort. Ağırlık",
            "home.scansThisWeek": "Bu Haftaki Taramalar",
            "home.muzzleIDs": "Burun Kimlikleri",
            "home.weightTrend": "Sürü Ağırlık Eğilimi",
            "home.recentScans": "Son Taramalar",
            "home.seeAll": "Tümünü Gör",
            "home.recentActions": "Son İşlemler",
            "home.noEvents": "Henüz işlem yok — burada görmek için bir hayvan kaydedin veya tanımlayın.",
            "home.needsScan": "Tarama Bekleyenler",

            // Tab bar
            "tab.home": "ana sayfa",
            "tab.animals": "hayvanlar",
            "tab.add": "ekle",
            "tab.settings": "ayarlar",

            // Statuses & results
            "status.healthy": "Sağlıklı",
            "status.pregnant": "Gebe",
            "status.attention": "Kontrol Gerekli",
            "scan.identified": "Tanımlandı",
            "scan.newID": "Yeni Kimlik",
            "scan.noMatch": "Eşleşme Yok",
            "sex.female": "Dişi",
            "sex.male": "Erkek",

            // Events (recent actions feed)
            "event.enrolled": "%@ — kaydedildi",
            "event.identified": "%@ — tanımlandı (%.2f)",
            "event.identifiedNoScore": "%@ — tanımlandı",
            "event.noMatch": "Bilinmeyen hayvan — eşleşme yok",
            "event.unknownAnimal": "Bilinmeyen hayvan",
            "common.retry": "Tekrar dene",
            "common.close": "Kapat",
            "common.loadError": "Verileriniz yüklenemedi.",

            // Animals
            "animals.title": "Sürüm",
            "animals.subtitle": "%d hayvan · %d kayıtlı burun kimliği",
            "animals.search": "İsim, küpe veya ırka göre ara",
            "filter.all": "Tümü",
            "filter.females": "Dişiler",
            "filter.males": "Erkekler",
            "animals.empty": "Hayvan bulunamadı",
            "animals.emptyHerd": "Henüz hayvan yok — ilkini eklemek için + simgesine dokunun.",
            "animals.lastScan": "Son tarama",
            "animals.never": "Hiç taranmadı",
            "unit.yr": "yıl",
            "unit.mo": "ay",
            "detail.title": "Hayvan Profili",
            "detail.muzzleID": "Burun Kimliği",
            "detail.notRegistered": "Kayıtlı Değil",
            "detail.enrolled": "Kayıt Tarihi",
            "detail.breed": "Irk",
            "detail.sex": "Cinsiyet",
            "detail.age": "Yaş",
            "detail.currentWeight": "Mevcut Ağırlık",
            "detail.lastScan": "Son Tarama",
            "detail.weightHistory": "Ağırlık Geçmişi",
            "detail.weighIns": "Tartımlar",
            "detail.notEnough": "Grafik için henüz yeterli tartım yok.",

            // Add animal
            "add.title": "Hayvan Ekle",
            "add.subtitle": "Sürünüze yeni bir hayvan kaydedin",
            "add.scanPrompt": "Kimlik için burnu tarayın",
            "add.scanDone": "Burun kimliği alındı",
            "add.scanHint": "Kamerayı hayvanın burnuna doğrultun — burun izi parmak izi kadar benzersizdir",
            "add.scanHintDone": "Bu hayvanın benzersiz burun deseni kaydedildi",
            "add.name": "İsim",
            "add.namePh": "örn. Sarıkız",
            "add.tag": "Küpe Numarası",
            "add.tagPh": "örn. TR-0412",
            "add.breed": "Irk",
            "add.dob": "Doğum Tarihi",
            "add.weight": "Mevcut Ağırlık (isteğe bağlı)",
            "add.weightPh": "örn. 420",
            "add.save": "Hayvanı Kaydet",
            "add.saved": "Hayvan sürüye eklendi",
            "edit.title": "Hayvanı Düzenle",
            "edit.subtitle": "Bu hayvanın bilgilerini güncelle",
            "edit.save": "Değişiklikleri Kaydet",
            "detail.edit": "Düzenle",
            "detail.delete": "Hayvanı Sil",
            "delete.confirmTitle": "Bu hayvan silinsin mi?",
            "delete.confirmBody": "Arşivlenip sürünüzden kaldırılacak. Hemen ardından geri alabilirsiniz.",
            "delete.confirm": "Sil",
            "common.cancel": "İptal",
            "undo.archived": "Hayvan arşivlendi",
            "undo.action": "Geri al",

            // Settings
            "settings.title": "Ayarlar",
            "settings.account": "Hesap",
            "settings.changeEmail": "E-postayı Değiştir",
            "settings.changePassword": "Şifreyi Değiştir",
            "settings.currentEmail": "Mevcut e-posta",
            "settings.newEmail": "Yeni e-posta",
            "settings.verificationCode": "Doğrulama kodu",
            "settings.verificationCodePh": "E-postadaki 6 haneli kod",
            "settings.sendCode": "Koda e-posta gönder",
            "settings.resendCode": "Kodu tekrar gönder",
            "settings.codeSent": "Size 6 haneli bir kod gönderdik. Onaylamak için aşağıya girin.",
            "settings.newPassword": "Yeni şifre",
            "settings.confirmNewPassword": "Yeni şifreyi onayla",
            "settings.newPasswordPh": "Yeni bir şifre girin",
            "settings.save": "Kaydet",
            "settings.saving": "Kaydediliyor…",
            "settings.emailUpdated": "Değişikliği onaylamak için yeni e-postanızı kontrol edin.",
            "settings.passwordUpdated": "Şifreniz güncellendi.",
            "settings.language": "Dil",
            "settings.preferences": "Tercihler",
            "settings.notifications": "Bildirimler",
            "settings.autoCapture": "Algılamada Otomatik Çekim",
            "settings.metric": "Metrik Birimler (kg)",
            "settings.about": "Hakkında",
            "settings.help": "Yardım ve Destek",
            "settings.privacy": "Gizlilik Politikası",
            "settings.version": "Sürüm",
            "settings.signout": "Çıkış Yap",

            // Camera
            "camera.mode.automatic": "Otomatik",
            "camera.mode.manual": "Manuel",
            "camera.hint.point": "Kamerayı ineğin başına doğrultun.",
            "camera.hint.hold": "Baş algılandı — sabit tutun…",
            "camera.hint.tap": "Baş hazır — çekmek için dokunun.",
            "camera.analyzing": "Fotoğraf analiz ediliyor…",
            "camera.help": "Yardım?",
            "camera.success.title": "Burun yakalandı!",
            "camera.success.msg": "Burun başarıyla algılandı ve kırpıldı.",
            "camera.failed.title": "Tarama başarısız",
            "camera.fail.read": "Fotoğraf okunamadı. Tekrar deneyin.",
            "camera.fail.crop": "Burun algılanamadı veya kırpılamadı. Tekrar deneyin.",
            "camera.viewResult": "Sonucu gör",
            "camera.scanAgain": "Tekrar tara",
            "camera.denied.title": "Kamera erişimi gerekli",
            "camera.denied.msg": "Hayvanları taramak için Ayarlar'dan kamera erişimine izin verin.",
            "camera.openSettings": "Ayarları Aç",
            "camera.guide.title": "Tarama rehberi",
            "camera.guide.body": "Hayvanı ekranınızdaki beyaz karenin içine alın. Mükemmel olması gerekmez — çerçevenin içinde kaldığı sürece tarama çalışacaktır.",
            "camera.guide.correct": "Doğru",
            "camera.guide.wrong": "Yanlış",
            "camera.guide.tip1": "Hayvan kareye rahatça sığana kadar yaklaşın veya uzaklaşın.",
            "camera.guide.tip2": "İyi bir ışık bulun ve fotoğrafı çekmeden önce telefonunuzu sabit tutun.",
            "camera.guide.tip3": "Hayvanı tamamen çerçevenin içinde tutun — kenarlardan kesilmesini önleyin.",
            "camera.understand": "Anladım",
            "camera.result.title": "Algılama sonucu",
            "camera.result.cropped": "Kırpılmış burun",
            "camera.result.full": "Tam fotoğraf",
            "camera.result.noCrop": "Burun kırpması oluşturulamadı.",
            "camera.result.noPhoto": "Fotoğraf yok.",
            "camera.done": "Tamam",
            "camera.enroll.progress": "Burun %d / %d",
            "camera.enroll.submitting": "Kaydediliyor…",
            "camera.enroll.success": "Hayvan kaydedildi",
            "camera.enroll.failed": "Kayıt başarısız",
            "camera.enroll.retry": "Kaydı tekrar dene",
            "camera.identify.identified": "Tanımlandı",
            "camera.identify.unknown": "Hayvan tanınmadı",
            "camera.identify.score": "Güven %%%.0f",
            "camera.identify.enroll": "Bu hayvanı kaydet",
            "camera.identify.waking": "Tanıyıcı uyandırılıyor…",
            "camera.identify.offline": "Ağ kullanılamıyor. Tekrar deneyin.",
            "camera.identify.retry": "Tekrar dene",
            "server.status.connecting": "Bağlanılıyor…",
            "server.status.offline": "Sunucu çevrimdışı — yeniden denemek için dokunun",

            // Recognition errors
            "recognition.error.notAuthenticated": "Oturum açılmamış.",
            "recognition.error.http": "Sunucu hatası (%d).",
            "recognition.error.network": "Ağ bağlantısı yok.",
            "recognition.error.encoding": "Görüntü hazırlanamadı.",
            "recognition.error.decoding": "Beklenmeyen sunucu yanıtı.",

            // Auth
            "auth.landing.subtitle": "Nasıl devam etmek istediğinizi seçin",
            "auth.signin": "Giriş Yap",
            "auth.signup": "Kayıt Ol",
            "auth.login.subtitle": "Tekrar hoş geldiniz. Devam etmek için giriş yapın.",
            "auth.method.email": "E-posta",
            "auth.method.phone": "Telefon",
            "auth.email": "E-posta",
            "auth.emailPh": "siz@ornek.com",
            "auth.phone": "Telefon numarası",
            "auth.password": "Şifre",
            "auth.passwordPh": "Şifrenizi girin",
            "auth.forgot": "Şifrenizi mi unuttunuz?",
            "auth.login": "Giriş yap",
            "auth.noAccount": "Hesabınız yok mu?",
            "auth.signupAction": "Kayıt ol",
            "auth.create": "Hesap Oluştur",
            "auth.fullName": "Ad soyad",
            "auth.fullNamePh": "Adınız",
            "auth.createPw": "Bir şifre oluşturun",
            "auth.confirmPw": "Şifreyi onayla",
            "auth.repeatPw": "Şifrenizi tekrar girin",
            "auth.haveAccount": "Zaten hesabınız var mı?",
            "auth.forgotTitle": "Şifremi Unuttum",
            "auth.forgotSubtitle": "E-posta veya telefon numaranızı girin, size sıfırlama bağlantısı gönderelim.",
            "auth.sendReset": "Sıfırlama Bağlantısı Gönder",
            "auth.remember": "Şifrenizi hatırladınız mı?",
            "auth.backToLogin": "Girişe dön",
            "auth.error.generic": "Bir şeyler ters gitti. Lütfen tekrar deneyin.",
            "auth.signingIn": "Giriş yapılıyor…",
            "auth.signingUp": "Hesap oluşturuluyor…",
            "auth.mismatch": "Şifreler eşleşmiyor.",
            "auth.confirmEmail": "Hesabınızı onaylamak için e-postanızı kontrol edin.",
        ],
    ]
}
