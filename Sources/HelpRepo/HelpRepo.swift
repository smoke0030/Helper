import SwiftUI
@preconcurrency import WebKit
import Network
import UserNotifications
import AdServices

@MainActor
class AppState: ObservableObject {
    @Published var state: AppStateStatus = .loading
}

enum AppStateStatus {
    case success(URL)
    case game(URL)
    case loading
}



final class Constants {
//    static var unlockDate = "%32%30%32%35%2D%30%34%2D%31%30"
    static var unlockDate = ""
    static var baseGameURL = ""
}
public class NetworkMonitor: ObservableObject {
    static var shared = NetworkMonitor()
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "monitor")
    @Published var isActive = false
    @Published var isExpansive = false
    @Published var isConstrained = false
    @Published var connectionType = NWInterface.InterfaceType.other
    
    // НОВОЕ: добавлена переменная для отслеживания предыдущего состояния
    private var wasDisconnected = false
    
    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                // НОВОЕ: сохраняем предыдущее состояние
                let wasConnected = self.isActive
                
                self.isActive = path.status == .satisfied
                self.isExpansive = path.isExpensive
                self.isConstrained = path.isConstrained
                
                let connectionTypes: [NWInterface.InterfaceType] = [.cellular, .wifi, .wiredEthernet]
                self.connectionType = connectionTypes.first(where: path.usesInterfaceType) ?? .other
                
                // НОВОЕ: Отслеживаем восстановление подключения
                if !wasConnected && self.isActive {
                    // Соединение было восстановлено
                    NotificationCenter.default.post(name: .internetConnectionRestored, object: nil)
                }
                
                // НОВОЕ: Запоминаем текущее состояние для определения изменения в будущем
                self.wasDisconnected = !self.isActive
            }
        }
        
        monitor.start(queue: queue)
    }
}




// MARK: - Error Handling

enum URLDecodingError: Error {
    case emptyParameters
    case invalidURL
    case emptyData
    case timeout
}

// MARK: - String Extension for Decoding

extension String {
    func decodePercentEncodedASCII() -> String {
        var result = ""
        var i = self.startIndex
        
        while i < self.endIndex {
            if self[i] == "%" && i < self.index(self.endIndex, offsetBy: -2) {
                let start = self.index(i, offsetBy: 1)
                let end = self.index(i, offsetBy: 3)
                let hexString = String(self[start..<end])
                
                if let hexValue = UInt32(hexString, radix: 16),
                   let unicode = UnicodeScalar(hexValue) {
                    result.append(Character(unicode))
                    i = end
                } else {
                    return ""
                }
            } else {
                result.append(self[i])
                i = self.index(after: i)
            }
        }
        
        return result
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
    static let updated = Notification.Name("urlUpdated")
    static let showGame = Notification.Name("showGame")
    static let internetConnectionRestored = Notification.Name("internetConnectionRestored")
}

// MARK: - Request Manager Protocol & Implementation

// ОБНОВЛЕНО: Добавлена логика обработки восстановления сети
@MainActor
public class RequestsManager: ObservableObject {
    @Published var showInternetALert = false
    @ObservedObject var monitor = NetworkMonitor.shared
    private let urlStorageKey = "receivedURL"
    private let hasLaunchedBeforeKey = "hasLaunchedBefore"
    private var apnsToken =  "token"
    private var attToken = "token"
    private var retryCount = 0
    private let maxRetryCount = 3
    private let retryDelay = 3.0
    
    // НОВОЕ: добавлен инициализатор для подписки на уведомления
    public init(date: String, url: String) {
        // Подписываемся на уведомление о восстановлении сети
        Constants.baseGameURL = url
        Constants.unlockDate = date
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInternetConnectionRestored),
            name: .internetConnectionRestored,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // НОВОЕ: добавлен обработчик восстановления соединения
    @objc private func handleInternetConnectionRestored() {
        // Когда интернет восстановлен
        if showInternetALert {
            // Если было показано предупреждение - скрываем его и повторяем запрос
            showInternetALert = false
            retryCount = 0
            Task {
                await getData()
            }
        }
    }
    
    // ОБНОВЛЕНО: Добавлен сброс счетчика и алерта при наличии соединения
    public func getData() async {
        guard checkUnlockDate(Constants.unlockDate.decodePercentEncodedASCII()) else {
            if let url = URL(string: getFinalUrl(data: [:])) {
                print("Показана игра")
                showGame(object: url)
            }
            
            return
        }
        
        if !monitor.isActive {
            await retryInternetConnection()
            return
        }
        
        // НОВОЕ: Если интернет доступен, сбрасываем счетчик повторов и предупреждение
        retryCount = 0
        showInternetALert = false
        
        if !isFirstLaunch() {
            handleStoredState()
            return
        }
        
        await getTokens()
    }
    
    private func handleStoredState() {
        if let urlString = UserDefaults.standard.string(forKey: urlStorageKey), let url = URL(string: urlString) {
            updateLoading(object: url)
        }
    }
    
    private func getFinalUrl(data: [String: String]) -> String {
        // Обработка случая с пустыми данными
        let safeData = data.isEmpty ? ["apns_token": "token", "att_token": "token"] : data
        
        let queryItems = safeData.map { URLQueryItem(name: $0.key, value: $0.value) }
        var components = URLComponents()
        components.queryItems = queryItems
        
        guard let queryString = components.query?.data(using: .utf8) else {
            // Если не удалось сформировать query, отправляем дефолтную строку
            let defaultBase64 = "apns_token=token&att_token=token".data(using: .utf8)!.base64EncodedString()
            return Constants.baseGameURL.decodePercentEncodedASCII() +
                   "%3F%64%61%74%61%3D".decodePercentEncodedASCII() +
                   defaultBase64
        }
        
        let base64String = queryString.base64EncodedString()
        let fullUrlString = Constants.baseGameURL.decodePercentEncodedASCII() +
                             "%2F%3F%64%61%74%61%3D".decodePercentEncodedASCII() +
                             base64String
        
        return fullUrlString
    }
    
    // Функция для повторных попыток подключения к интернету
    private func retryInternetConnection() async {
        // Проверяем, не превышено ли максимальное количество попыток
        if retryCount >= maxRetryCount {
            DispatchQueue.main.async {
                self.showInternetALert = true
            }
            retryCount = 0 // Сбрасываем счетчик для будущих попыток
            return
        }
        
        // Увеличиваем счетчик попыток и выводим информацию
        retryCount += 1
        
        // Ожидаем указанное время перед повторной попыткой
        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        
        // Повторная проверка интернета
        if monitor.isActive {
            retryCount = 0 // Сбрасываем счетчик, так как подключение восстановлено
            
            // Продолжаем выполнение основного кода в зависимости от типа запуска
            if !isFirstLaunch() {
                handleStoredState()
            } else {
                await getTokens()
            }
        } else {
            // Продолжаем попытки, если не достигли максимума
            await retryInternetConnection()
        }
    }

    // Получение токенов для устройства
    private func getTokens() async {
        await withCheckedContinuation { continuation in
            // Регистрируемся для получения push-уведомлений
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            
            // Попытка получить ATT токен
            do {
                self.attToken = try AAAttribution.attributionToken()
            } catch {
                self.attToken = "token"
            }
            
            let timeout = DispatchTime.now() + 5
            
            // Наблюдатель для получения APNS токена
            NotificationCenter.default.addObserver(forName: .apnsTokenReceived, object: nil, queue: .main) { [weak self] notification in
                guard let self = self else { return }
                
                if let token = notification.userInfo?["token"] as? String {
                    Task { @MainActor in
                        self.apnsToken = token
                        if let url = URL(string: self.getFinalUrl(data: self.getDeviceData()))  {
                            self.sendNTFQuestionToUser()
                            self.handleFirstLaunchSuccess(url: url)
                        }
                        continuation.resume()
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: timeout) { [weak self] in
                guard let self = self else { return }
                
                // Проверяем на пустую строку, т.к. исходно инициализируем как "token"
                if self.apnsToken.isEmpty || self.apnsToken == "token" {
                    Task { @MainActor in
                        self.apnsToken = "token"  // Гарантированно устанавливаем дефолтное значение
                        
                        let urlString = self.getFinalUrl(data: self.getDeviceData())
                        
                        // Гарантированно создаем URL даже в случае проблем с формированием
                        if let url = URL(string: urlString) {
                            self.sendNTFQuestionToUser()
                            self.handleFirstLaunchSuccess(url: url)
                        }
                        
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    // Получение данных устройства для отправки
    func getDeviceData() -> [String: String] {
        // Гарантированно возвращаем непустые значения
        let safeApnsToken = apnsToken.isEmpty ? "token" : apnsToken
        let safeAttToken = attToken.isEmpty ? "token" : attToken
        
        let data = [
            "apns_token": safeApnsToken,
            "att_token": safeAttToken
        ]
        return data
    }
    
    // Проверка, является ли это первым запуском
    private func isFirstLaunch() -> Bool {
        !UserDefaults.standard.bool(forKey: hasLaunchedBeforeKey)
    }
    
    // Обработка успешного первого запуска
    private func handleFirstLaunchSuccess(url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: urlStorageKey)
        UserDefaults.standard.set(true, forKey: hasLaunchedBeforeKey)
        updateLoading(object: url)
    }
    
    // Проверка даты разблокировки
    func checkUnlockDate(_ date: String) -> Bool {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let currentDate = Date()
        guard let unlockDate = dateFormatter.date(from: date), currentDate >= unlockDate else {
            return false
        }
        return true
    }
    
    // Проверка, нужно ли показывать WebView
    func isShowWV() -> Bool {
        // Приложение показывает WebView если оно уже запускалось (не первый запуск)
        return UserDefaults.standard.bool(forKey: hasLaunchedBeforeKey)
    }
    
    // Запрос разрешения на отправку уведомлений
    func sendNTFQuestionToUser() {
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(options: authOptions) {_, _ in }
    }
}

// MARK: - RequestsManager Notifications Extension

extension RequestsManager {
    func updateLoading(object: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationCenter.default.post(name: .updated, object: object)
        }
    }
    
    func showGame(object: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationCenter.default.post(name: .showGame, object: object)
        }
    }
}
