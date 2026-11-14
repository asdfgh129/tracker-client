/*
 * TrackerOne · Traccar Webhook Notificator
 *
 * 作用：把 Traccar 事件以 HTTP POST 推送到自建推送网关（中国大陆推送链路）。
 *
 * 说明：
 * - 本文件是 Traccar 6.16 的**插件补丁**，不属于 trackerone Flutter 工程；
 * - Traccar 没有通用 webhook 通知器，必须新增 notificator 并在
 *   `NotificatorManager.NOTIFICATORS_ALL` 注册；
 * - 许可证与 Traccar 一致：Apache-2.0。
 */
package org.traccar.notificators;

import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.traccar.config.Config;
import org.traccar.model.Device;
import org.traccar.model.Event;
import org.traccar.model.Position;
import org.traccar.model.User;
import org.traccar.notification.NotificationFormatter;
import org.traccar.notification.NotificationMessage;
import org.traccar.session.cache.CacheManager;

/**
 * 把事件推送到自建网关（网关再调用极光 / 厂商通道）。
 *
 * 配置（traccar.xml）：
 * <pre>
 * &lt;entry key='notificator.types'&gt;web,mail,webhook&lt;/entry&gt;
 * &lt;entry key='notificator.webhook.url'&gt;https://push.example.com/v1/events&lt;/entry&gt;
 * &lt;entry key='notificator.webhook.secret'&gt;请替换为随机密钥&lt;/entry&gt;
 * &lt;entry key='notificator.webhook.timeoutSeconds'&gt;5&lt;/entry&gt;
 * </pre>
 *
 * 签名：`X-Traccar-Signature: sha256=<hex(hmac_sha256(body, secret))>`
 */
@Singleton
public class NotificatorWebhook extends Notificator {

    private static final Logger LOGGER = LoggerFactory.getLogger(NotificatorWebhook.class);

    /** M-10：网关或前置代理返回大体积错误页时截断日志，避免刷爆 Traccar 日志。 */
    private static final int MAX_LOGGED_BODY = 256;

    private final Config config;
    private final CacheManager cacheManager;
    private final ObjectMapper objectMapper;
    private final HttpClient httpClient;

    @Inject
    public NotificatorWebhook(
            Config config, NotificationFormatter notificationFormatter,
            CacheManager cacheManager, ObjectMapper objectMapper) {
        super(notificationFormatter);
        this.config = config;
        this.cacheManager = cacheManager;
        this.objectMapper = objectMapper;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
    }

    @Override
    public CompletableFuture<Void> sendAsync(
            // 签名由 Traccar 的 Notificator 抽象类约定；position 不再外发
            //（M-10 数据最小化），保留参数以匹配父类契约。
            @SuppressWarnings("unused") Position position) {

        String url = config.getString("notificator.webhook.url");
        if (url == null || url.isBlank()) {
            return CompletableFuture.failedFuture(
                    new IllegalStateException("notificator.webhook.url is not configured"));
        }

        try {
            // M-10 数据最小化（PIPL 最小必要）：只发网关投递与模板所需的字段。
            // 不再发送 userEmail、uniqueId 与完整 Event/Position 对象 ——
            // 网关只需 event.id / event.type / deviceName / message 文案。
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("version", 1);
            payload.put("userId", user.getId());
            payload.put("deviceId", event.getDeviceId());

            Device device = cacheManager.getObject(Device.class, event.getDeviceId());
            if (device != null) {
                payload.put("deviceName", device.getName());
            }

            Map<String, Object> eventSummary = new LinkedHashMap<>();
            eventSummary.put("id", event.getId());
            eventSummary.put("type", event.getType());
            eventSummary.put("eventTime", String.valueOf(event.getEventTime()));
            if (event.getGeofenceId() > 0) {
                eventSummary.put("geofenceId", event.getGeofenceId());
            }
            payload.put("event", eventSummary);

            Map<String, Object> text = new LinkedHashMap<>();
            text.put("title", message.subject());
            text.put("body", message.body());
            text.put("digest", message.digest());
            payload.put("message", text);
            payload.put("issuedAt", System.currentTimeMillis());

            String body = objectMapper.writeValueAsString(payload);

            // M-10：默认强制 HTTPS（含邮箱/设备名/位置的 payload 不得明文传输）。
            // 本地联调可显式开启 notificator.webhook.allowHttp=true。
            URI endpoint = URI.create(url);
            boolean allowHttp = parseBoolean(
                    config.getString("notificator.webhook.allowHttp"), false);
            if (endpoint.getScheme() == null
                    || (!"https".equalsIgnoreCase(endpoint.getScheme()) && !allowHttp)) {
                LOGGER.warn(
                        "Webhook URL 必须是 https；已丢弃事件 {}（如需明文请设"
                                + " notificator.webhook.allowHttp=true）",
                        event.getId());
                return CompletableFuture.failedFuture(
                        new IllegalStateException("insecure webhook url"));
            }

            long timeoutSeconds = parseLong(
                    config.getString("notificator.webhook.timeoutSeconds"), 5L);
            HttpRequest.Builder builder = HttpRequest.newBuilder(endpoint)
                    .timeout(Duration.ofSeconds(timeoutSeconds))
                    .header("Content-Type", "application/json; charset=utf-8")
                    .header("User-Agent", "traccar-webhook/1")
                    .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));

            // M-10：缺密钥时 fail-closed —— 绝不能无签名投递（网关会 401，
            // 但更早失败能避免把事件内容发到不可信端点）。
            String secret = config.getString("notificator.webhook.secret");
            if (secret == null || secret.isBlank()) {
                LOGGER.warn("notificator.webhook.secret 未配置，已丢弃事件 {}（拒绝无签名投递）",
                        event.getId());
                return CompletableFuture.failedFuture(
                        new IllegalStateException("webhook secret not configured"));
            }
            builder.header("X-Traccar-Signature", "sha256=" + hmacSha256(body, secret));

            return httpClient.sendAsync(builder.build(), HttpResponse.BodyHandlers.ofString())
                    .thenAccept(response -> {
                        if (response.statusCode() / 100 != 2) {
                            LOGGER.warn(
                                    "Webhook rejected event {} for user {}: HTTP {} {}",
                                    event.getId(), user.getId(),
                                    response.statusCode(),
                                    truncate(response.body()));
                            throw new CompletionException(new IllegalStateException(
                                    "Webhook returned HTTP " + response.statusCode()));
                        }
                    });

        } catch (Exception error) {
            LOGGER.warn("Webhook delivery failed for event {}", event.getId(), error);
            return CompletableFuture.failedFuture(error);
        }
    }

    private static boolean parseBoolean(String value, boolean fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        return Boolean.parseBoolean(value.trim());
    }

    private static String truncate(String body) {
        if (body == null) {
            return "";
        }
        return body.length() <= MAX_LOGGED_BODY
                ? body
                : body.substring(0, MAX_LOGGED_BODY) + "…(truncated)";
    }

    private static long parseLong(String value, long fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException error) {
            return fallback;
        }
    }

    private static String hmacSha256(String body, String secret) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        byte[] digest = mac.doFinal(body.getBytes(StandardCharsets.UTF_8));
        StringBuilder builder = new StringBuilder(digest.length * 2);
        for (byte value : digest) {
            builder.append(String.format("%02x", value));
        }
        return builder.toString();
    }
}
