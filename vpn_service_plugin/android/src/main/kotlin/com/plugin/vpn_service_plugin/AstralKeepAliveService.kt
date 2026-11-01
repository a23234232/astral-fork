package com.plugin.vpn_service_plugin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// 连接保活前台服务。
//
// 背景（issue #263）：连接通知原先由 Dart 侧 flutter_local_notifications 作为普通
// ongoing 通知发出，唯一的取消入口在正常断开流程中。进程被 kill -9 / 系统回收时
// Dart 无法执行任何代码，而 Android 只会清理「前台服务」持有的通知，
// 普通通知因此永久残留。
//
// 解决：把连接通知交给本前台服务持有。本服务不建立 TUN，也不被 BIND_VPN_SERVICE
// 绑定，只负责让通知与前台服务的生命周期绑定——进程结束（含被强杀）时，
// 系统会自动移除本服务持有的通知，从根上消除残留。
//
// 注意：TauriVpnService 仍然用普通 startService 启动，不提升为前台服务；
// 只有本服务调用 startForeground（#264 的错误是把 TauriVpnService 改成
// startForegroundService 却从不调用 startForeground，会导致系统 crash 进程）。
class AstralKeepAliveService : Service() {
    companion object {
        // 通知渠道/ID 与原 Dart 通知保持一致：升级后旧版本遗留的通知会被同 ID 覆盖
        const val CHANNEL_ID = "astral_connection"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.plugin.vpn_service_plugin.KEEPALIVE_START"
        const val ACTION_STOP = "com.plugin.vpn_service_plugin.KEEPALIVE_STOP"
        const val EXTRA_STATUS = "status"
        const val EXTRA_IP = "ip"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_SHOW_CONTENT = "show_content"

        // 静态引用：供 MethodChannel 直接更新通知内容。
        // 服务未创建 / 已销毁时为 null，调用方必须做 null 安全处理。
        @JvmField
        var instance: AstralKeepAliveService? = null
    }

    // 是否展示完整内容（用户在设置里关闭「连接通知」时只保留一条最小通知）
    private var showContent = true

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 停止动作不需要提升前台，直接退出即可
        if (intent?.action == ACTION_STOP) {
            stopMe()
            return START_NOT_STICKY
        }

        showContent = intent?.getBooleanExtra(EXTRA_SHOW_CONTENT, showContent) ?: showContent
        val status = intent?.getStringExtra(EXTRA_STATUS) ?: "连接中"
        val ip = intent?.getStringExtra(EXTRA_IP) ?: "正在获取..."
        val duration = intent?.getStringExtra(EXTRA_DURATION) ?: "00:00"

        // 关键：通过 startForegroundService 启动后必须在时限内调用 startForeground，
        // 否则系统会直接 crash 进程。这里无条件提升为前台。
        try {
            promote(status, ip, duration, showContent)
        } catch (e: Exception) {
            // 极端情况下（机型/权限限制）无法提升前台：立即停止服务，
            // 避免系统判定「startForegroundService 未及时 startForeground」而 crash 进程
            println("AstralKeepAlive startForeground failed: $e")
            stopMe()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // 更新通知内容（连接成功后每秒刷新 IP / 时长）
    fun update(status: String, ip: String, duration: String) {
        // 用户已关闭通知内容时保持最小通知，避免被滞后的更新重新显示内容
        if (!showContent) {
            notifyContent(buildNotification("", "", "", false))
            return
        }
        notifyContent(buildNotification(status, ip, duration, true))
    }

    // 关闭通知内容（用户关闭「连接通知」开关）。
    // 注意：Android 不允许前台服务没有通知，因此这里只能退化成一条最小通知，
    // 无法做到完全不显示；但该最小通知仍会在进程结束时被系统一并清理。
    fun hideContent() {
        showContent = false
        notifyContent(buildNotification("", "", "", false))
    }

    // 重新展示完整内容（用户重新打开「连接通知」开关）
    fun showContentAgain(status: String, ip: String, duration: String) {
        showContent = true
        notifyContent(buildNotification(status, ip, duration, true))
    }

    // 主动停止服务并移除前台通知（幂等，可被插件侧多次调用）
    fun stopMe() {
        removeForegroundNotification()
        instance = null
        stopSelf()
    }

    override fun onDestroy() {
        // 兜底清理：无论正常停止还是系统销毁，都移除前台状态与通知
        removeForegroundNotification()
        instance = null
        super.onDestroy()
    }

    // 将服务提升为前台服务（Android 14+ 需要显式前台服务类型）
    private fun promote(status: String, ip: String, duration: String, withContent: Boolean) {
        val notification = buildNotification(status, ip, duration, withContent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+：manifest 中声明了 foregroundServiceType="specialUse"，
            // 这里必须传入 FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // 更新已展示的通知内容
    private fun notifyContent(notification: Notification) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }

    // 移除前台状态并取消通知（旧版本 Android 无三参 stopForeground）
    @Suppress("DEPRECATION")
    private fun removeForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    // 创建通知渠道（Android 8.0+）
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Astral 连接状态",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示 Astral 连接状态和信息"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    // 构建通知；withContent=false 时只展示一条最小通知
    @Suppress("DEPRECATION")
    private fun buildNotification(
        status: String,
        ip: String,
        duration: String,
        withContent: Boolean,
    ): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        // 小图标：优先使用应用图标，异常情况下退回系统图标，避免前台通知无效导致崩溃
        val smallIcon = applicationInfo.icon
        if (smallIcon != 0) {
            builder.setSmallIcon(smallIcon)
        } else {
            builder.setSmallIcon(android.R.drawable.stat_notify_sync)
        }

        builder
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        // 点击通知回到应用主界面
        buildContentIntent()?.let { builder.setContentIntent(it) }

        if (withContent) {
            builder.setContentTitle("Astral - $status")
            if (ip.isNotEmpty()) {
                builder.setContentText("IP: $ip | 连接时间: $duration")
            }
        } else {
            // 最小通知：不展示状态 / IP / 时长
            builder.setContentTitle("Astral")
        }

        return builder.build()
    }

    // 构建点击通知回到应用的 PendingIntent
    private fun buildContentIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        // FLAG_IMMUTABLE 在 API 23+ 才存在；低版本会忽略该未知 flag，不影响原有行为
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
