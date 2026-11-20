// API tests: the real server, a real (throwaway) MySQL database, and HTTP
// calls as the app makes them. Covers sign-in and access rules, the jersey
// number rules with Player Validation, and kit orders.
//
// Skipped unless TEST_MYSQL_PASSWORD is set: see support/test_server.dart.

@Timeout(Duration(minutes: 3))
library;

import 'package:test/test.dart';

import '../lib/notices.dart' show sendBirthdayGreetings;
import 'support/test_server.dart';

void main() {
  if (skipReason != null) {
    test('API tests', () {}, skip: skipReason);
    return;
  }

  late TestServer server;
  late Client admin;
  late Client anyone;
  late ({int id, Client client}) alpha;
  late ({int id, Client client}) beta;

  setUpAll(() async {
    server = await TestServer.start();
    admin = await server.logInAdmin();
    anyone = Client(server.base, null);
    alpha = await server.newParent(admin, 'alphaparent', 'Alpha Parent');
    beta = await server.newParent(admin, 'betaparent', 'Beta Parent');
  });

  tearDownAll(() async {
    await server.stop();
  });

  /// Adds a child for [parent]; [allowTaken] is the family pressing CONTINUE
  /// on the "number already taken" warning.
  Future<Reply> addChild(
    Client parent,
    String name,
    String birthday,
    String jersey, {
    bool allowTaken = false,
  }) => parent.post('/players', {
    'fullName': name,
    'birthday': birthday,
    'jerseyNumber': jersey,
    'jerseySize': 'M',
    if (allowTaken) 'allowTaken': true,
  });

  Future<int> idOf(Reply reply) async {
    expect(reply.status, 201, reason: '$reply');
    return reply.json['id'] as int;
  }

  Future<String> playerState(int id) => server.value(
    "SELECT CONCAT(is_approved, '/', IFNULL(jersey_number, '-'), '/', "
    "IFNULL(jersey_request, '-'), '/', IFNULL(jersey_request_status, '-')) "
    'FROM players WHERE id = :id',
    {'id': id},
  );

  Future<String> latestJerseyNotice(int playerId) => server.value(
    "SELECT CONCAT(a.title, ' | ', a.body) FROM announcements a "
    'JOIN announcement_players ap ON ap.announcement_id = a.id '
    "WHERE a.auto_kind = 'jersey_number' AND ap.player_id = :id "
    'AND a.deleted_at IS NULL ORDER BY a.id DESC LIMIT 1',
    {'id': playerId},
  );

  group('sign-in and access', () {
    test('the server reports healthy', () async {
      expect((await anyone.get('/health')).status, 200);
    });

    test('a wrong password is refused', () async {
      final reply = await anyone.post('/auth/login', {
        'identifier': adminLogin.username,
        'password': 'wrong-password',
      });
      expect(reply.status, 401);
    });

    test('nothing is readable without signing in', () async {
      expect((await anyone.get('/players')).status, 401);
      expect((await anyone.get('/orders')).status, 401);
    });

    test('a new account waits for the admin before it can sign in', () async {
      final signup = await anyone.post('/auth/signup', {
        'username': 'waitingparent',
        'fullName': 'Waiting Parent',
        'email': 'waitingparent@example.com',
        'phone': '+971 50 000 0001',
        'password': 'test-pass-123',
      });
      expect(signup.status, 201);
      final login = await anyone.post('/auth/login', {
        'identifier': 'waitingparent',
        'password': 'test-pass-123',
      });
      expect(login.status, isNot(200));
    });

    test('parents cannot use admin screens', () async {
      expect((await alpha.client.get('/player-validation')).status, 403);
      expect((await alpha.client.get('/admin/parents')).status, 403);
    });
  });

  group('jersey numbers', () {
    late int ann;
    late int ben;

    test('a free number is given at once', () async {
      ann = await idOf(
        await addChild(alpha.client, 'Ann Alpha', '2013-03-03', '91'),
      );
      expect(await playerState(ann), '1/91/-/-');
    });

    test('a taken number is refused until the family confirms', () async {
      final reply = await addChild(beta.client, 'Ben Beta', '2013-04-04', '91');
      expect(reply.status, 409);
      expect(reply.json['code'], 'jersey_taken');
      // Never names another family's child.
      expect(reply.body, isNot(contains('Ann Alpha')));
    });

    test('one number per academy, whatever the birth year', () async {
      final reply = await addChild(
        alpha.client,
        'Cal Alpha',
        '2015-05-05',
        '91',
      );
      expect(reply.json['code'], 'jersey_taken');
    });

    test('"07" and "7" are the same shirt', () async {
      await idOf(await addChild(alpha.client, 'Sev Alpha', '2014-01-01', '7'));
      final reply = await addChild(beta.client, 'Zed Beta', '2014-02-02', '07');
      expect(reply.json['code'], 'jersey_taken');
    });

    test('parents see which numbers are taken, but not by whom', () async {
      final reply = await beta.client.get('/jersey-numbers');
      expect(reply.json['taken'], contains(91));
      expect((reply.json as Map).containsKey('holders'), isFalse);
      final forAdmin = await admin.get('/jersey-numbers');
      expect(forAdmin.json['holders']['91'], ['Ann Alpha (B2013)']);
    });

    test(
      'confirming a taken number puts the child on Player Validation',
      () async {
        final reply = await addChild(
          beta.client,
          'Ben Beta',
          '2013-04-04',
          '91',
          allowTaken: true,
        );
        ben = await idOf(reply);
        expect(reply.json['pending'], isTrue);
        // Not a player yet, no number yet, asking for #91.
        expect(await playerState(ben), '0/-/91/pending');
      },
    );

    test('a waiting child is not on the admin list and cannot order', () async {
      expect((await admin.get('/players')).body, isNot(contains('Ben Beta')));
      expect((await beta.client.get('/players')).body, contains('Ben Beta'));
      final order = await beta.client.post('/orders', {
        'playerId': ben,
        'orderItemId': 1,
      });
      expect(order.status, 404);
    });

    test('Player Validation lists the request with who wears it', () async {
      final reply = await admin.get('/player-validation');
      final request = (reply.json as List).singleWhere(
        (row) => row['full_name'] == 'Ben Beta',
      );
      expect(request['jersey_request'], '91');
      expect(request['worn_by'], 'Ann Alpha (B2013)');
    });

    test('parents cannot approve their own request', () async {
      final reply = await beta.client.post('/player-validation/$ben/approve');
      expect(reply.status, 403);
    });

    test('the admin can approve with a different number', () async {
      final reply = await admin.post('/player-validation/$ben/approve', {
        'jerseyNumber': 92,
      });
      expect(reply.status, 200, reason: '$reply');
      expect(await playerState(ben), '1/92/-/-');
      final notice = await latestJerseyNotice(ben);
      expect(notice, contains('Ben Beta has been added'));
      expect(
        notice,
        contains('You asked for #91; the academy chose #92 instead'),
      );
    });

    test('a request can only be answered once', () async {
      final reply = await admin.post('/player-validation/$ben/approve');
      expect(reply.status, 404);
    });

    test(
      'an existing player asking for a taken number keeps theirs while waiting',
      () async {
        final reply = await beta.client.put('/players/$ben', {
          'fullName': 'Ben Beta',
          'birthday': '2013-04-04',
          'jerseyNumber': '91',
          'jerseySize': 'M',
          'allowTaken': true,
        });
        expect(reply.status, 200, reason: '$reply');
        expect(await playerState(ben), '1/92/91/pending');
      },
    );

    test('declining keeps the old number and tells the family', () async {
      final reply = await admin.post('/player-validation/$ben/decline');
      expect(reply.status, 200, reason: '$reply');
      expect(await playerState(ben), '1/92/91/declined');
      expect(
        await latestJerseyNotice(ben),
        contains('Jersey #91 not approved'),
      );
    });

    test('number 0 is a real number', () async {
      final dee = await idOf(
        await addChild(alpha.client, 'Dee Alpha', '2014-07-07', '0'),
      );
      expect(await playerState(dee), '1/0/-/-');
      expect(
        (await beta.client.get('/jersey-numbers')).json['taken'],
        contains(0),
      );
    });
  });

  group('kit orders', () {
    late int player;
    late int order;

    setUpAll(() async {
      player = await idOf(
        await addChild(alpha.client, 'Ola Alpha', '2012-02-02', '55'),
      );
    });

    test('a parent orders; the price comes from the server', () async {
      final reply = await alpha.client.post('/orders', {
        'playerId': player,
        'orderItemId': 1,
        'amount': 1, // ignored
      });
      expect(reply.status, 201, reason: '$reply');
      order = reply.json['id'] as int;
      expect(
        await server.value('SELECT amount FROM orders WHERE id = :id', {
          'id': order,
        }),
        '130.00',
      );
    });

    test("parents cannot order for another family's child", () async {
      final reply = await beta.client.post('/orders', {
        'playerId': player,
        'orderItemId': 1,
      });
      expect(reply.status, 404);
    });

    test('a pending order cannot be marked as given', () async {
      expect((await admin.post('/orders/$order/received')).status, 409);
    });

    test('approving turns the order into a bill', () async {
      expect((await admin.post('/orders/$order/approve')).status, 200);
      final mine = (await alpha.client.get('/orders')).json as List;
      final row = mine.singleWhere((o) => o['id'] == '$order');
      expect(row['status'], 'approved');
      expect(row['payment_status'], 'pending');
    });

    test('only the admin marks it as given, and can undo it', () async {
      expect((await alpha.client.post('/orders/$order/received')).status, 403);
      expect((await admin.post('/orders/$order/received')).status, 200);
      final given = await server.value(
        "SELECT IFNULL(received_at, 'none') FROM orders WHERE id = :id",
        {'id': order},
      );
      expect(given, isNot('none'));

      expect((await admin.delete('/orders/$order/received')).status, 200);
      final undone = await server.value(
        "SELECT IFNULL(received_at, 'none') FROM orders WHERE id = :id",
        {'id': order},
      );
      expect(undone, 'none');
    });
  });

  // ---- November 2026 batch ------------------------------------------------

  Future<int> playerNamed(String name) async => int.parse(
    await server.value('SELECT id FROM players WHERE full_name = :n', {
      'n': name,
    }),
  );

  /// Automatic messages of [kind] addressed to [playerId].
  Future<int> noticesFor(int playerId, String kind) async => int.parse(
    await server.value(
      'SELECT COUNT(*) FROM announcements a '
      'JOIN announcement_players ap ON ap.announcement_id = a.id '
      'WHERE a.auto_kind = :kind AND ap.player_id = :id '
      'AND a.deleted_at IS NULL',
      {'kind': kind, 'id': playerId},
    ),
  );

  group('jersey 00', () {
    test('00 is its own number: free even though 0 is taken', () async {
      // Dee Alpha already wears 0 (jersey numbers group).
      final zero = await idOf(
        await addChild(beta.client, 'Zero Beta', '2014-03-03', '00'),
      );
      expect(await playerState(zero), '1/00/-/-');
    });

    test('a second 00 is taken, and the message says #00', () async {
      final reply = await addChild(
        alpha.client,
        'Double Alpha',
        '2014-04-04',
        '00',
      );
      expect(reply.status, 409);
      expect(reply.json['code'], 'jersey_taken');
      expect(reply.body, contains('#00'));
    });

    test('the taken list stays plain numbers for the 1.0.23 app', () async {
      final reply = await beta.client.get('/jersey-numbers');
      final taken = reply.json['taken'] as List;
      expect(taken, everyElement(isA<int>()));
      expect(taken, contains(0));
      expect(taken, isNot(contains(-1)));
      expect(reply.json['doubleZeroTaken'], isTrue);
      final forAdmin = await admin.get('/jersey-numbers');
      expect(forAdmin.json['holders']['00'], ['Zero Beta (B2014)']);
      expect(forAdmin.json['holders']['0'], ['Dee Alpha (B2014)']);
    });

    test('asking for a taken 00 goes to Player Validation as 00', () async {
      final reply = await addChild(
        alpha.client,
        'Double Alpha',
        '2014-04-04',
        '00',
        allowTaken: true,
      );
      final id = await idOf(reply);
      expect(await playerState(id), '0/-/00/pending');
      final list = (await admin.get('/player-validation')).json as List;
      final row = list.singleWhere((r) => r['full_name'] == 'Double Alpha');
      expect(row['worn_by'], 'Zero Beta (B2014)');
      // The admin approves it as 00 (sent as text, as the app does).
      final approve = await admin.post('/player-validation/$id/approve', {
        'jerseyNumber': '00',
      });
      expect(approve.status, 200, reason: '$approve');
      expect(await playerState(id), '1/00/-/-');
      expect(await latestJerseyNotice(id), contains('jersey #00'));
    });
  });

  group('jersey sizes', () {
    Future<Reply> addSized(String name, String size) => alpha.client.post(
      '/players',
      {'fullName': name, 'birthday': '2015-06-06', 'jerseySize': size},
    );
    Future<String> sizeOf(int id) => server.value(
      'SELECT jersey_size FROM players WHERE id = :id',
      {'id': id},
    );

    test('the new sizes are accepted', () async {
      // Names are letters only, so each child gets a made-up one.
      final sizes = {
        '3XS': 'Tess',
        '2XS': 'Tom',
        '2XL': 'Xia',
        '3XL': 'Xander',
        '9-10': 'Nina',
        '11-12': 'Eli',
      };
      for (final MapEntry(key: size, value: name) in sizes.entries) {
        final id = await idOf(await addSized('$name Alpha', size));
        expect(await sizeOf(id), size);
      }
    });

    test('XXS from the 1.0.23 app is saved as 2XS', () async {
      final id = await idOf(await addSized('Old Alpha', 'XXS'));
      expect(await sizeOf(id), '2XS');
    });

    test('an unknown size is refused', () async {
      final reply = await addSized('Bad Alpha', 'XXXL');
      expect(reply.status, 400);
    });
  });

  group('categories', () {
    test('B0000 can be added, as the special any-age group', () async {
      final reply = await admin.post('/categories', {'code': 'B0000'});
      expect(reply.status, 201, reason: '$reply');
      expect(
        await server.value("SELECT label FROM categories WHERE code = 'B0000'"),
        'Special (any age)',
      );
    });

    test('other impossible years are still refused', () async {
      expect((await admin.post('/categories', {'code': 'B1949'})).status, 400);
      expect((await admin.post('/categories', {'code': 'B2999'})).status, 400);
    });
  });

  group('paid notices', () {
    late int ola;

    setUpAll(() async {
      ola = await playerNamed('Ola Alpha');
    });

    Future<int> newBill(num amount) async {
      final reply = await admin.post('/payments', {
        'playerId': ola,
        'type': 'misc',
        'title': 'Training Uniform',
        'miscType': 'uniform',
        'amount': amount,
      });
      expect(reply.status, 201, reason: '$reply');
      return reply.json['id'] as int;
    }

    test('marking a bill paid tells the family', () async {
      final before = await noticesFor(ola, 'payment_paid');
      final bill = await newBill(100);
      expect(await noticesFor(ola, 'payment_paid'), before);
      expect((await admin.post('/payments/$bill/paid', {})).status, 200);
      expect(await noticesFor(ola, 'payment_paid'), before + 1);
      final mine = (await alpha.client.get('/announcements')).body;
      expect(mine, contains('has been marked as paid'));
      expect(mine, contains('Order paid'));
      // Another family doesn't see it.
      final theirs = (await beta.client.get('/announcements')).body;
      expect(theirs, isNot(contains('Training Uniform for Ola Alpha')));
    });

    test('only once the bill is fully paid', () async {
      final before = await noticesFor(ola, 'payment_paid');
      final bill = await newBill(100);
      await admin.post('/payments/$bill/pay', {'amount': 40});
      expect(await noticesFor(ola, 'payment_paid'), before);
      await admin.post('/payments/$bill/pay', {'amount': 60});
      expect(await noticesFor(ola, 'payment_paid'), before + 1);
    });

    // Families don't pay in the app: only the academy records a payment
    // (lib/auth.dart keeps /payments/<id>/pay admin-only). So a family can't
    // mark its own bill paid, and nothing is sent.
    test('a family cannot mark its own bill paid', () async {
      final before = await noticesFor(ola, 'payment_paid');
      final bill = await newBill(50);
      final paid = await alpha.client.post('/payments/$bill/pay', {
        'amount': 50,
      });
      expect(paid.status, 403, reason: '$paid');
      expect(
        await server.value('SELECT status FROM payments WHERE id = :id', {
          'id': bill,
        }),
        'pending',
      );
      expect(await noticesFor(ola, 'payment_paid'), before);
    });
  });

  group('tournament reminders and declines', () {
    late int cup;
    late int ann;
    late int ben;

    setUpAll(() async {
      ann = await playerNamed('Ann Alpha');
      ben = await playerNamed('Ben Beta');
      final created = await admin.post('/tournaments', {
        'name': 'Test Cup',
        'category': 'B2013',
        'location': 'Dubai',
      });
      expect(created.status, 201, reason: '$created');
      cup = created.json['id'] as int;
      final added = await admin.post('/tournaments/$cup/players', {
        'playerIds': [ann, ben],
      });
      expect(added.status, lessThan(300), reason: '$added');
    });

    test('families cannot send reminders', () async {
      expect((await alpha.client.post('/tournaments/$cup/remind')).status, 403);
    });

    test('the admin reminds everyone still waiting, once', () async {
      final reply = await admin.post('/tournaments/$cup/remind');
      expect(reply.json['reminded'], 2);
      expect(await noticesFor(ann, 'tournament_reminder'), 1);
      expect(await noticesFor(ben, 'tournament_reminder'), 1);
      expect(
        (await alpha.client.get('/announcements')).body,
        contains('Reminder: Test Cup'),
      );
      // A double tap: nobody gets a second one.
      final again = await admin.post('/tournaments/$cup/remind');
      expect(again.json['reminded'], 0);
      expect(again.json['skipped'], 2);
    });

    test('declining without a reason is refused (the 1.0.23 app)', () async {
      final reply = await alpha.client.post(
        '/tournaments/$cup/players/$ann/consent',
        {'accept': false},
      );
      expect(reply.status, 400);
      expect(reply.json['code'], 'reason_required');
      expect(reply.body, contains('update the DSA Elite app'));
      expect(reply.body, isNot(contains('/')));
    });

    test('a reason over 300 characters is refused', () async {
      final reply = await alpha.client.post(
        '/tournaments/$cup/players/$ann/consent',
        {'accept': false, 'reason': 'x' * 301},
      );
      expect(reply.status, 400);
    });

    test('declining with a reason tells only the admin', () async {
      final reply = await alpha.client.post(
        '/tournaments/$cup/players/$ann/consent',
        {'accept': false, 'reason': "We're travelling that weekend"},
      );
      expect(reply.status, 200, reason: '$reply');
      expect(
        await server.value(
          'SELECT decline_reason FROM tournament_players '
          'WHERE tournament_id = :t AND player_id = :p',
          {'t': cup, 'p': ann},
        ),
        "We're travelling that weekend",
      );
      final adminMessages = (await admin.get('/announcements')).body;
      expect(adminMessages, contains('Ann Alpha declined Test Cup'));
      expect(adminMessages, contains("Reason: We're travelling that weekend"));
      for (final family in [alpha.client, beta.client]) {
        expect(
          (await family.get('/announcements')).body,
          isNot(contains('declined Test Cup')),
        );
      }
    });

    test('the admin reads the reason on the tournament', () async {
      final list = (await admin.get('/tournaments')).json as List;
      final t = list.singleWhere((x) => '${x['id']}' == '$cup');
      final ids = [for (final id in t['player_ids'] as List) id as int];
      final reasons = t['player_decline_reasons'] as List;
      expect(reasons[ids.indexOf(ann)], "We're travelling that weekend");
      expect(reasons[ids.indexOf(ben)], isNull);
    });

    test('a declined family is not reminded', () async {
      // Ben was reminded under two minutes ago, Ann declined: nobody.
      final reply = await admin.post('/tournaments/$cup/remind');
      expect(reply.json['reminded'], 0);
      expect(reply.json['skipped'], 1);
    });

    test('accepting afterwards clears the reason', () async {
      final reply = await alpha.client.post(
        '/tournaments/$cup/players/$ann/consent',
        {'accept': true},
      );
      expect(reply.status, 200, reason: '$reply');
      expect(
        await server.value(
          "SELECT IFNULL(decline_reason, 'none') FROM tournament_players "
          'WHERE tournament_id = :t AND player_id = :p',
          {'t': cup, 'p': ann},
        ),
        'none',
      );
    });
  });

  // ---- November 2026 batch, part 2 ---------------------------------------

  /// A child of [parent] with every field the edit form sends.
  Map<String, Object?> childBody(
    String name,
    String birthday,
    String jersey, {
    Object? nickname,
  }) => {
    'fullName': name,
    'birthday': birthday,
    'jerseyNumber': jersey,
    'jerseySize': 'M',
    'nickname': ?nickname,
  };

  Future<String> nicknameOf(int id) => server.value(
    "SELECT IFNULL(nickname, '-') FROM players WHERE id = :id",
    {'id': id},
  );

  group('nicknames', () {
    late int nico;

    test('a family can give one when adding a child, tidied', () async {
      nico = await idOf(
        await alpha.client.post(
          '/players',
          childBody('Nico Alpha', '2014-05-05', '41', nickname: '  Ki   ko '),
        ),
      );
      expect(await nicknameOf(nico), 'Ki ko');
      final mine = (await alpha.client.get('/players')).json as List;
      expect(
        mine.singleWhere((p) => '${p['id']}' == '$nico')['nickname'],
        'Ki ko',
      );
    });

    test('a family cannot change it afterwards', () async {
      final reply = await alpha.client.put(
        '/players/$nico',
        childBody('Nico Alpha', '2014-05-05', '41', nickname: 'Boss'),
      );
      expect(reply.status, lessThan(300), reason: '$reply');
      expect(await nicknameOf(nico), 'Ki ko');
    });

    test('the academy can change it', () async {
      final reply = await admin.put(
        '/players/$nico',
        childBody('Nico Alpha', '2014-05-05', '41', nickname: 'Kiko'),
      );
      expect(reply.status, lessThan(300), reason: '$reply');
      expect(await nicknameOf(nico), 'Kiko');
    });

    test('an update without the field keeps it (the 1.0.23 app)', () async {
      final reply = await admin.put(
        '/players/$nico',
        childBody('Nico Alpha', '2014-05-05', '41'),
      );
      expect(reply.status, lessThan(300), reason: '$reply');
      expect(await nicknameOf(nico), 'Kiko');
    });

    test('the academy can clear it', () async {
      await admin.put(
        '/players/$nico',
        childBody('Nico Alpha', '2014-05-05', '41', nickname: '  '),
      );
      expect(await nicknameOf(nico), '-');
      await admin.put(
        '/players/$nico',
        childBody('Nico Alpha', '2014-05-05', '41', nickname: 'Kiko'),
      );
    });

    test('too long or with emoji is refused', () async {
      for (final bad in ['x' * 31, 'Kiko 🏀']) {
        final reply = await admin.put(
          '/players/$nico',
          childBody('Nico Alpha', '2014-05-05', '41', nickname: bad),
        );
        expect(reply.status, 400, reason: bad);
      }
      expect(await nicknameOf(nico), 'Kiko');
    });
  });

  group('birthday messages', () {
    late int bea;

    setUpAll(() async {
      final born = await server.value(
        "SELECT DATE_FORMAT(CURDATE() - INTERVAL 10 YEAR, '%Y-%m-%d')",
      );
      bea = await idOf(
        await alpha.client.post(
          '/players',
          childBody('Bea Alpha', born, '42', nickname: 'Bee'),
        ),
      );
    });

    test('the child is wished a happy birthday, by nickname', () async {
      final db = await server.openDb();
      try {
        expect(await sendBirthdayGreetings(db, fromHour: 0), greaterThan(0));
      } finally {
        await db.pool.close();
      }
      expect(await noticesFor(bea, 'birthday'), 1);
      final mine = (await alpha.client.get('/announcements')).body;
      expect(mine, contains('Happy Birthday, Bee!'));
      expect(mine, contains('Happy 10th birthday, Bea Alpha!'));
    });

    test('only that family sees it', () async {
      expect(
        (await beta.client.get('/announcements')).body,
        isNot(contains('Happy Birthday, Bee')),
      );
    });

    test('once a year, however often the job runs', () async {
      final db = await server.openDb();
      try {
        await sendBirthdayGreetings(db, fromHour: 0);
        await sendBirthdayGreetings(db, fromHour: 0);
      } finally {
        await db.pool.close();
      }
      expect(await noticesFor(bea, 'birthday'), 1);
    });

    test('nothing goes out before the send hour', () async {
      final db = await server.openDb();
      try {
        // Hour 24 never comes.
        expect(await sendBirthdayGreetings(db, fromHour: 24), 0);
      } finally {
        await db.pool.close();
      }
    });
  });

  group('the academy answering for a family', () {
    late int cup;
    late int nico;

    setUpAll(() async {
      nico = await playerNamed('Nico Alpha');
      final created = await admin.post('/tournaments', {
        'name': 'Game Cup',
        'category': 'B2013',
        'location': 'Dubai',
      });
      expect(created.status, 201, reason: '$created');
      cup = created.json['id'] as int;
      final added = await admin.post('/tournaments/$cup/players', {
        'playerIds': [nico],
      });
      expect(added.status, lessThan(300), reason: '$added');
      final priced = await admin.put('/tournaments/$cup/amounts', {
        '$nico': 250,
      });
      expect(priced.status, lessThan(300), reason: '$priced');
    });

    Future<Reply> bill() => admin.post('/payments', {
      'playerId': nico,
      'type': 'tournament',
      'title': 'Game Cup Fee',
      'amount': 250,
      'tournamentId': cup,
    });

    Future<Map> onTournament() async {
      final list = (await admin.get('/tournaments')).json as List;
      return list.singleWhere((x) => '${x['id']}' == '$cup') as Map;
    }

    test('no bill before anyone has accepted', () async {
      expect((await bill()).status, greaterThanOrEqualTo(400));
    });

    test('the academy accepts; the list says the academy answered', () async {
      final reply = await admin.post(
        '/tournaments/$cup/players/$nico/consent',
        {'accept': true},
      );
      expect(reply.status, 200, reason: '$reply');
      final t = await onTournament();
      final at = (t['player_ids'] as List).indexOf(nico);
      expect((t['player_consents'] as List)[at], 'accepted');
      expect((t['player_answered_by_academy'] as List)[at], isTrue);
    });

    test('the bill then goes to the family, like any other', () async {
      final reply = await bill();
      expect(reply.status, 201, reason: '$reply');
      final theirs = (await alpha.client.get('/payments')).body;
      expect(theirs, contains('Game Cup Fee'));
      expect(
        await server.value(
          "SELECT CONCAT(status, '/', IFNULL(pushed_at, 'queued')) "
          'FROM payments WHERE tournament_id = :t AND player_id = :p',
          {'t': cup, 'p': nico},
        ),
        'pending/queued',
      );
      expect(
        (await beta.client.get('/payments')).body,
        isNot(contains('Game Cup Fee')),
      );
    });

    test('once billed, the answer is locked', () async {
      final reply = await alpha.client.post(
        '/tournaments/$cup/players/$nico/consent',
        {'accept': false, 'reason': 'Changed our mind'},
      );
      expect(reply.status, greaterThanOrEqualTo(400));
    });
  });

  group('standings and game results', () {
    late int cup;
    late int past;
    late int future;
    late int today;
    late int noOpponent;

    Future<int> game(String day, String? opponent) async {
      await server.value(
        'INSERT INTO sessions (session_type, tournament_id, category_label, '
        'session_date, start_time, location, opponent) '
        "VALUES ('tournament', :t, 'B2013', $day, '10:00', 'DSA Gym', :o)",
        {'t': cup, 'o': opponent},
      );
      return int.parse(await server.value('SELECT MAX(id) FROM sessions'));
    }

    Future<Map> standingOf(String name) async {
      final list =
          (await admin.get('/tournaments/$cup/opponents')).json as List;
      return list.singleWhere((o) => o['name'] == name) as Map;
    }

    Future<Reply> result(Client who, int id, Object? dsa, Object? them) =>
        who.put('/tournaments/$cup/games/$id/result', {
          'dsaScore': dsa,
          'opponentScore': them,
        });

    setUpAll(() async {
      final list = (await admin.get('/tournaments')).json as List;
      // Ids come back as text on this list.
      cup = int.parse(
        '${list.singleWhere((x) => x['name'] == 'Game Cup')['id']}',
      );
      past = await game('CURDATE() - INTERVAL 2 DAY', 'vs. Grind');
      future = await game('CURDATE() + INTERVAL 3 DAY', 'vs. Lakers');
      today = await game('CURDATE()', 'vs. Grind');
      noOpponent = await game('CURDATE() - INTERVAL 1 DAY', null);
    });

    test('the academy adds teams; a repeat is refused, any case', () async {
      for (final name in ['Grind', 'Lakers']) {
        final reply = await admin.post('/tournaments/$cup/opponents', {
          'name': name,
        });
        expect(reply.status, 201, reason: '$reply');
      }
      final again = await admin.post('/tournaments/$cup/opponents', {
        'name': '  grind ',
      });
      expect(again.status, 409);
      expect(again.json['error'], 'Grind is already on the list');
    });

    test('a team name must be real text', () async {
      for (final bad in ['', '   ', 'x' * 41, 'Hoops 🏀']) {
        final reply = await admin.post('/tournaments/$cup/opponents', {
          'name': bad,
        });
        expect(reply.status, 400, reason: bad);
      }
    });

    test('the games come back in order, with nothing scored', () async {
      final games = (await admin.get('/tournaments/$cup/games')).json as List;
      expect(
        [for (final g in games) g['id']],
        [past, noOpponent, today, future],
      );
      expect(games.every((g) => g['dsa_score'] == null), isTrue);
      expect(games.last['upcoming'], isTrue);
    });

    test('a result needs both scores, and no tie', () async {
      expect((await result(admin, past, 54, null)).status, 400);
      expect((await result(admin, past, 54, 'x')).status, 400);
      expect((await result(admin, past, -1, 3)).status, 400);
      expect((await result(admin, past, 1000, 3)).status, 400);
      final tie = await result(admin, past, 50, 50);
      expect(tie.status, 400);
      expect(tie.body, contains('tie'));
    });

    test('an unplayed game or one with no opponent cannot be scored', () async {
      expect((await result(admin, future, 54, 48)).status, 409);
      expect((await result(admin, noOpponent, 54, 48)).status, 409);
    });

    test('a win counts towards the standing', () async {
      final reply = await result(admin, past, 54, 48);
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['dsa_score'], 54);
      final grind = await standingOf('Grind');
      expect((grind['dsa_wins'], grind['opponent_wins']), (1, 0));
      final lakers = await standingOf('Lakers');
      expect((lakers['dsa_wins'], lakers['opponent_wins']), (0, 0));
    });

    test('a loss counts for the other side', () async {
      expect((await result(admin, today, 40, 61)).status, 200);
      final grind = await standingOf('Grind');
      expect((grind['dsa_wins'], grind['opponent_wins']), (1, 1));
    });

    test('changing only the place keeps the score', () async {
      final reply = await admin.put('/sessions/$today', {
        'location': 'DSA Court 2',
      });
      expect(reply.status, 200, reason: '$reply');
      expect(
        await server.value(
          "SELECT CONCAT(dsa_score, '-', opponent_score) FROM sessions "
          'WHERE id = :id',
          {'id': today},
        ),
        '40-61',
      );
    });

    test('changing the opponent clears the score', () async {
      final reply = await admin.put('/sessions/$today', {
        'opponent': 'vs. Lakers',
      });
      expect(reply.status, 200, reason: '$reply');
      expect(
        await server.value(
          "SELECT IFNULL(dsa_score, 'none') FROM sessions WHERE id = :id",
          {'id': today},
        ),
        'none',
      );
      final grind = await standingOf('Grind');
      expect((grind['dsa_wins'], grind['opponent_wins']), (1, 0));
    });

    test('a cancelled game no longer counts', () async {
      await server.value(
        'UPDATE sessions SET is_cancelled = 1 WHERE id = :id',
        {'id': past},
      );
      final grind = await standingOf('Grind');
      expect((grind['dsa_wins'], grind['opponent_wins']), (0, 0));
      final games = (await admin.get('/tournaments/$cup/games')).json as List;
      expect(games.any((g) => g['id'] == past), isFalse);
      expect((await result(admin, past, 1, 2)).status, 404);
      await server.value(
        'UPDATE sessions SET is_cancelled = 0 WHERE id = :id',
        {'id': past},
      );
    });

    test('a result can be taken back off', () async {
      final reply = await result(admin, past, null, null);
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['dsa_score'], isNull);
      final grind = await standingOf('Grind');
      expect((grind['dsa_wins'], grind['opponent_wins']), (0, 0));
      await result(admin, past, 54, 48);
    });

    test("a family on the tournament can read it, but not change it", () async {
      final standings = await alpha.client.get('/tournaments/$cup/opponents');
      expect(standings.status, 200, reason: '$standings');
      expect(standings.body, contains('Grind'));
      expect((await alpha.client.get('/tournaments/$cup/games')).status, 200);
      expect((await result(alpha.client, past, 99, 1)).status, 403);
      expect(
        (await alpha.client.post('/tournaments/$cup/opponents', {
          'name': 'Hackers',
        })).status,
        403,
      );
    });

    test('another family cannot see it at all', () async {
      expect(
        (await beta.client.get('/tournaments/$cup/opponents')).status,
        404,
      );
      expect((await beta.client.get('/tournaments/$cup/games')).status, 404);
    });
  });

  group('bill descriptions', () {
    const breakdown =
        '350 - October Fees\n400 - PEBA 2007\n55 - Previous Balance';

    Future<Reply> others(String? description) async {
      final ola = await playerNamed('Ola Alpha');
      return admin.post('/payments', {
        'playerId': ola,
        'type': 'misc',
        'title': 'Others',
        'miscType': 'others',
        'description': ?description,
        'amount': 805,
      });
    }

    Map billIn(List bills, int id) =>
        bills.singleWhere((b) => '${b['id']}' == '$id') as Map;

    test('the family gets it exactly as typed, line breaks too', () async {
      final sent = await others(breakdown);
      expect(sent.status, 201, reason: '$sent');
      final id = sent.json['id'] as int;
      final theirs = (await alpha.client.get('/payments')).json as List;
      expect(billIn(theirs, id)['description'], breakdown);
      final academy = (await admin.get('/payments')).json as List;
      expect(billIn(academy, id)['description'], breakdown);
    });

    test('another family never sees it', () async {
      expect(
        (await beta.client.get('/payments')).body,
        isNot(contains('PEBA 2007')),
      );
    });

    test('several Others bills each keep their own', () async {
      final a = (await others('Team photo print')).json['id'] as int;
      final b = (await others('Bus fare, away game')).json['id'] as int;
      final theirs = (await alpha.client.get('/payments')).json as List;
      expect(billIn(theirs, a)['description'], 'Team photo print');
      expect(billIn(theirs, b)['description'], 'Bus fare, away game');
    });

    test('none given, or only spaces, is stored as none', () async {
      for (final none in [null, '', '   ']) {
        final id = (await others(none)).json['id'] as int;
        final theirs = (await alpha.client.get('/payments')).json as List;
        expect(billIn(theirs, id)['description'], isNull, reason: '$none');
      }
    });

    test('over 2000 characters is refused', () async {
      expect((await others('x' * 2001)).status, 400);
    });
  });
}
