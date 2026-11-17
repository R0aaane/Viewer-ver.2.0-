// Explicit opt-in: transfers existing local images to the configured real host.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/scene/generated_gallery_page.dart';
import 'package:pdf_viewer/services/app_settings_service.dart';
import 'package:pdf_viewer/services/local_generation_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local generated image relays to host and is visible from client gallery', (tester) async {
    if (!const bool.fromEnvironment('LIVE_HOST_RELAY')) return;
    final settings = await AppSettingsService().loadMetadataSettings();
    expect(settings.isClientMode,isTrue);
    final token = await LocalGenerationService.instance.start(requireComfy:false);
    final local = GeneratedMediaRepository(LocalGenerationService.baseUrl,token);
    final remote = GeneratedMediaRepository(settings.remoteApiBaseUrl,settings.authToken);
    addTearDown(local.close); addTearDown(remote.close);
    final page = await local.search({'limit':48});
    final ids = (page['items'] as List).map((row)=>row['mediaId'] as String).toList();
    expect(ids,isNotEmpty);
    final deadline = DateTime.now().add(const Duration(minutes:20));
    var transferred = false;
    while(DateTime.now().isBefore(deadline)) {
      final status = await local.relayStatus();
      final items = (status?['items'] as List? ?? []);
      if(ids.every((id)=>items.any((row)=>row['mediaId']==id && row['state']=='sent'))) { transferred=true;break; }
      await tester.pump(const Duration(seconds:2));
    }
    expect(transferred,isTrue,reason:'Host update/receive library must become available');
    final id = ids.first;
    final localBytes = await local.originalBytes(id);
    final hostBytes = await remote.originalBytes(id);
    expect(sha256.convert(hostBytes).toString(),id);
    expect(hostBytes,localBytes);
    final detail = await remote.detail(id);
    await tester.pumpWidget(MaterialApp(home:GeneratedGalleryPage(baseUrl:settings.remoteApiBaseUrl,
      token:settings.authToken,libraryLabel:'ホスト')));
    final uiDeadline = DateTime.now().add(const Duration(minutes:1));
    while(find.text(detail['name'] as String).evaluate().isEmpty && DateTime.now().isBefore(uiDeadline)) {
      await tester.pump(const Duration(milliseconds:200));
    }
    expect(find.text('生成画像（ホスト）'),findsOneWidget);
    expect(find.text(detail['name'] as String),findsWidgets);
    await File('.dart_tool/image-prompt/host-relay-live-result.json').writeAsString(jsonEncode({
      'hostImageId':id,'transferredCount':ids.length,'originalHashMatched':true,'visibleInHostGallery':true,
    }));
    await tester.pumpWidget(const SizedBox());await tester.pumpAndSettle();
  },timeout:const Timeout(Duration(minutes:25)));
}
