import 'dart:math' as math;

import 'package:astral/features/rooms/widgets/network_topology_ids.dart';
import 'package:astral/features/rooms/widgets/network_topology_models.dart';
import 'package:astral/shared/utils/platform_version_parser.dart';
import 'package:astral/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

/// 拓扑画布布局参数：按编辑器可视区域自适应，保证所有节点落在画布可视
/// 范围内（#244：节点列表中有、但位置超出可视区域导致「消失」）。
class TopologyCanvasLayout {
  final double localX;
  final double targetX;
  final double baseY;
  final double rowGap;
  final double maxY;

  const TopologyCanvasLayout({
    required this.localX,
    required this.targetX,
    required this.baseY,
    required this.rowGap,
    required this.maxY,
  });

  /// 节点卡片宽度（与 [NetworkTopologyNodes.buildNode] 的非紧凑宽度一致）。
  static const double nodeWidth = 220;

  /// 拿不到编辑器尺寸时的回退画布。
  static const double fallbackWidth = 900;
  static const double fallbackHeight = 640;

  factory TopologyCanvasLayout.forViewport(Size? viewport, int rowCount) {
    final width =
        (viewport != null && viewport.width.isFinite && viewport.width > 0)
            ? viewport.width
            : fallbackWidth;
    final height =
        (viewport != null && viewport.height.isFinite && viewport.height > 0)
            ? viewport.height
            : fallbackHeight;

    const margin = 20.0;
    // 顶部预留图例卡片高度，避免节点被图例遮挡。
    const legendHeight = 24.0;
    // 节点卡片高度估算（标题 + 正文），用于给行间距兜底。
    const rowCardHeight = 96.0;

    final rows = math.max(1, rowCount);
    final usableHeight = math.max(
      rowCardHeight,
      height - margin * 2 - legendHeight,
    );
    final rawGap = rows > 1 ? usableHeight / (rows - 1) : rowCardHeight;
    final rowGap = rawGap.clamp(56.0, 130.0).toDouble();

    final localX = margin;
    // 右列尽量贴右；画布过窄时至少与左列留出连线距离。
    final targetX = math.max(
      localX + nodeWidth + 96.0,
      width - nodeWidth - margin,
    );
    final baseY = margin + legendHeight;
    final maxY = baseY + (rows - 1) * rowGap;

    return TopologyCanvasLayout(
      localX: localX,
      targetX: targetX,
      baseY: baseY,
      rowGap: rowGap,
      maxY: maxY,
    );
  }

  /// 把历史坐标夹取到当前画布内，避免窗口变小/布局重排后节点跑到可视区外。
  Offset clampPosition(Offset position) {
    final maxX = math.max(localX, targetX);
    final minY = math.min(baseY, maxY);
    final maxYValue = math.max(baseY, maxY);
    return Offset(
      position.dx.clamp(localX, maxX).toDouble(),
      position.dy.clamp(minY, maxYValue).toDouble(),
    );
  }
}

/// Builds topology node/connection models from peer list data.
class NetworkTopologyBuild {
  NetworkTopologyBuild._();

  // 兼容旧调用方的回退常量；实际布局由 [TopologyCanvasLayout] 按可视区域计算。
  static const double localX = 120;
  static const double targetX = 760;
  static const double baseY = 80;
  static const double rowGap = 130;

  static TopologyGraphModel buildGraphModel(
    List<KVNodeInfo> nodes, {
    required String localIp,
    required Map<String, Offset> existingPositions,
    required bool shouldAnimateConnections,
    Size? viewport,
  }) {
    final newNodes = <String, Node<TopologyNodeData>>{};
    final newConnections = <String, Connection>{};
    final nodeIdsByPeerId = <int, String>{};
    final nodeIdsByFallbackKey = <String, String>{};
    final nodeRowIndex = <String, int>{};

    KVNodeInfo? localNode;
    for (final node in nodes) {
      if (node.ipv4 == localIp && localIp.isNotEmpty) {
        localNode = node;
        break;
      }
    }

    final nonLocalServers = <KVNodeInfo>[];
    final nonLocalPlayers = <KVNodeInfo>[];

    for (final node in nodes) {
      if (localNode != null && node.peerId == localNode.peerId) {
        continue;
      }
      if (NetworkTopologyIds.isServerNode(node)) {
        nonLocalServers.add(node);
      } else {
        nonLocalPlayers.add(node);
      }
    }

    nonLocalServers.sort((a, b) => a.peerId.compareTo(b.peerId));
    nonLocalPlayers.sort((a, b) => a.peerId.compareTo(b.peerId));

    final hasLaneSpacer =
        nonLocalServers.isNotEmpty && nonLocalPlayers.isNotEmpty;
    final totalRows =
        nonLocalServers.length +
        nonLocalPlayers.length +
        (hasLaneSpacer ? 1 : 0);

    // 按编辑器可视区域计算画布布局：行距/右列 X 随窗口自适应，
    // 避免节点数较多或窗口变小时节点落到可视区外（#244）。
    final layout = TopologyCanvasLayout.forViewport(viewport, totalRows);

    final nonLocalIndexByPeerId = <int, int>{};
    final nonLocalIndexByFallbackKey = <String, int>{};

    for (var i = 0; i < nonLocalServers.length; i++) {
      final server = nonLocalServers[i];
      if (server.peerId > 0) {
        nonLocalIndexByPeerId[server.peerId] = i;
      }
      nonLocalIndexByFallbackKey[NetworkTopologyIds.nodeFallbackKey(server)] =
          i;
    }

    for (var i = 0; i < nonLocalPlayers.length; i++) {
      final player = nonLocalPlayers[i];
      final row = i + nonLocalServers.length + (hasLaneSpacer ? 1 : 0);
      if (player.peerId > 0) {
        nonLocalIndexByPeerId[player.peerId] = row;
      }
      nonLocalIndexByFallbackKey[NetworkTopologyIds.nodeFallbackKey(player)] =
          row;
    }

    int rowIndex = 0;
    for (final nodeInfo in nodes) {
      final isLocal = localNode != null && nodeInfo.peerId == localNode.peerId;
      final isServer = NetworkTopologyIds.isServerNode(nodeInfo);
      final nodeId = NetworkTopologyIds.nodeIdForPeerId(
        nodeInfo.peerId,
        NetworkTopologyIds.nodeFallbackKey(nodeInfo),
      );

      if (nodeInfo.peerId > 0) {
        nodeIdsByPeerId[nodeInfo.peerId] = nodeId;
      }
      nodeIdsByFallbackKey[NetworkTopologyIds.nodeFallbackKey(nodeInfo)] =
          nodeId;

      final displayName = NetworkTopologyIds.normalizeNodeName(
        nodeInfo.hostname,
      );
      late final Offset position;

      if (existingPositions.containsKey(nodeId)) {
        // 复用已有坐标，但夹取到当前画布内：窗口缩小或节点数变化后
        // 旧坐标可能落在可视区外，看起来就像节点「消失」（#244）。
        position = layout.clampPosition(existingPositions[nodeId]!);
      } else if (isLocal) {
        final localY = layout.baseY + ((totalRows - 1) * layout.rowGap / 2);
        position = Offset(layout.localX, localY);
      } else {
        final index =
            nonLocalIndexByPeerId[nodeInfo.peerId] ??
            nonLocalIndexByFallbackKey[NetworkTopologyIds.nodeFallbackKey(
              nodeInfo,
            )] ??
            -1;
        final effectiveIndex = index >= 0 ? index : rowIndex;
        position = Offset(
          layout.targetX,
          layout.baseY + (effectiveIndex * layout.rowGap),
        );
        nodeRowIndex[nodeId] = effectiveIndex;
        rowIndex = math.max(rowIndex, effectiveIndex + 1);
      }

      newNodes[nodeId] = Node<TopologyNodeData>(
        id: nodeId,
        type: isLocal ? 'local' : (isServer ? 'server' : 'player'),
        position: position,
        data: TopologyNodeData(
          displayName: displayName,
          ip: isServer && !isLocal ? null : nodeInfo.ipv4,
          type:
              isLocal
                  ? TopologyNodeType.local
                  : (isServer
                      ? TopologyNodeType.server
                      : TopologyNodeType.player),
          platform: PlatformVersionParser.getPlatformName(nodeInfo.version),
          latency: isLocal ? 0 : nodeInfo.latencyMs.toInt(),
        ),
        inputPorts: [
          Port(
            id: 'in',
            name: '',
            position: PortPosition.left,
            offset: const Offset(-2, 0),
          ),
        ],
        outputPorts: [
          Port(
            id: 'out',
            name: '',
            position: PortPosition.right,
            offset: const Offset(2, 0),
          ),
        ],
      );
    }

    final localNodeId =
        localNode == null
            ? null
            : NetworkTopologyIds.resolveNodeId(
              peerId: localNode.peerId,
              fallbackKey: NetworkTopologyIds.nodeFallbackKey(localNode),
              nodeIdsByPeerId: nodeIdsByPeerId,
              nodeIdsByFallbackKey: nodeIdsByFallbackKey,
            );

    if (localNodeId == null) {
      return TopologyGraphModel(newNodes, newConnections);
    }

    for (final nodeInfo in nodes) {
      if (localNode != null && nodeInfo.peerId == localNode.peerId) {
        continue;
      }

      final targetId =
          NetworkTopologyIds.resolveNodeId(
            peerId: nodeInfo.peerId,
            fallbackKey: NetworkTopologyIds.nodeFallbackKey(nodeInfo),
            nodeIdsByPeerId: nodeIdsByPeerId,
            nodeIdsByFallbackKey: nodeIdsByFallbackKey,
          ) ??
          NetworkTopologyIds.nodeIdForPeerId(
            nodeInfo.peerId,
            NetworkTopologyIds.nodeFallbackKey(nodeInfo),
          );

      if (nodeInfo.hops.isNotEmpty) {
        String previousNodeId = localNodeId;
        final targetRow = nodeRowIndex[targetId] ?? 0;
        final hopCount = nodeInfo.hops.length;

        for (var hopIndex = 0; hopIndex < nodeInfo.hops.length; hopIndex++) {
          final hop = nodeInfo.hops[hopIndex];
          final hopId =
              NetworkTopologyIds.resolveNodeId(
                peerId: hop.peerId,
                fallbackKey: NetworkTopologyIds.hopFallbackKey(hop),
                nodeIdsByPeerId: nodeIdsByPeerId,
                nodeIdsByFallbackKey: nodeIdsByFallbackKey,
              ) ??
              NetworkTopologyIds.nodeIdForPeerId(
                hop.peerId,
                NetworkTopologyIds.hopFallbackKey(hop),
              );

          if (!newNodes.containsKey(hopId)) {
            final displayName = NetworkTopologyIds.normalizeNodeName(
              hop.nodeName.isNotEmpty ? hop.nodeName : 'relay_${hop.targetIp}',
            );
            final hopX =
                layout.localX +
                ((layout.targetX - layout.localX) / (hopCount + 1)) *
                    (hopIndex + 1);
            final position =
                existingPositions.containsKey(hopId)
                    ? layout.clampPosition(existingPositions[hopId]!)
                    : Offset(
                      hopX,
                      layout.baseY + (targetRow * layout.rowGap),
                    );

            newNodes[hopId] = Node<TopologyNodeData>(
              id: hopId,
              type: 'relay',
              position: position,
              data: TopologyNodeData(
                displayName: displayName,
                ip: hop.targetIp,
                type: TopologyNodeType.relay,
                platform: 'Relay',
                latency: hop.latencyMs.toInt(),
              ),
              inputPorts: [
                Port(
                  id: 'in',
                  name: '',
                  position: PortPosition.left,
                  offset: const Offset(-2, 0),
                ),
              ],
              outputPorts: [
                Port(
                  id: 'out',
                  name: '',
                  position: PortPosition.right,
                  offset: const Offset(2, 0),
                ),
              ],
            );
          }

          if (previousNodeId != hopId) {
            final connId = NetworkTopologyIds.connectionId(
              previousNodeId,
              hopId,
            );
            newConnections[connId] = Connection(
              id: connId,
              sourceNodeId: previousNodeId,
              sourcePortId: 'out',
              targetNodeId: hopId,
              targetPortId: 'in',
              animationEffect:
                  shouldAnimateConnections ? ConnectionEffects.particles : null,
              label: ConnectionLabel(
                text: NetworkTopologyIds.formatLatencyLabel(hop.latencyMs),
              ),
            );
          }

          previousNodeId = hopId;
        }

        if (previousNodeId != targetId) {
          final connId = NetworkTopologyIds.connectionId(
            previousNodeId,
            targetId,
          );
          newConnections[connId] = Connection(
            id: connId,
            sourceNodeId: previousNodeId,
            sourcePortId: 'out',
            targetNodeId: targetId,
            targetPortId: 'in',
            animationEffect:
                shouldAnimateConnections ? ConnectionEffects.particles : null,
            label: ConnectionLabel(
              text: NetworkTopologyIds.formatLatencyLabel(nodeInfo.latencyMs),
            ),
          );
        }
      } else {
        if (localNodeId != targetId) {
          final connId = NetworkTopologyIds.connectionId(localNodeId, targetId);
          newConnections[connId] = Connection(
            id: connId,
            sourceNodeId: localNodeId,
            sourcePortId: 'out',
            targetNodeId: targetId,
            targetPortId: 'in',
            animationEffect:
                shouldAnimateConnections ? ConnectionEffects.particles : null,
            label: ConnectionLabel(
              text: NetworkTopologyIds.formatLatencyLabel(nodeInfo.latencyMs),
            ),
          );
        }
      }
    }

    return TopologyGraphModel(newNodes, newConnections);
  }
}
