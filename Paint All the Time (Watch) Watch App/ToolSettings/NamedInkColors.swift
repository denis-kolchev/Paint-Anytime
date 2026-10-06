// Names from the user-provided list (1–500), in original order.
// Duplicate HEX values always retain the earliest name.
enum NamedInkColors {
    static func name(forHex hex: String) -> String? {
        namesByHex[hex.uppercased()]
    }

    private static let namesByHex: [String: String] = {
        var names: [String: String] = [:]
        for entry in entries where names[entry.hex] == nil {
            names[entry.hex] = entry.name
        }
        return names
    }()

    private static let entries: [(hex: String, name: String)] = [
        ("#000080", "Navy"), // 1
        ("#008080", "Teal"), // 2
        ("#00FFFF", "Cyan / Aqua"), // 3
        ("#40E0D0", "Turquoise"), // 4
        ("#4B0082", "Indigo"), // 5
        ("#EE82EE", "Violet"), // 6
        ("#FF00FF", "Magenta / Fuchsia"), // 7
        ("#DC143C", "Crimson"), // 8
        ("#FF2400", "Scarlet"), // 9
        ("#800000", "Maroon"), // 10
        ("#800020", "Burgundy"), // 11
        ("#FF7F50", "Coral"), // 12
        ("#FA8072", "Salmon"), // 13
        ("#FF6347", "Tomato"), // 14
        ("#FFD700", "Gold"), // 15
        ("#FFBF00", "Amber"), // 16
        ("#FFDB58", "Mustard"), // 17
        ("#F0E68C", "Khaki"), // 18
        ("#F5F5DC", "Beige"), // 19
        ("#FFFFF0", "Ivory"), // 20
        ("#FFFDD0", "Cream"), // 21
        ("#D2B48C", "Tan"), // 22
        ("#D2691E", "Chocolate"), // 23
        ("#A0522D", "Sienna"), // 24
        ("#635147", "Umber"), // 25
        ("#808000", "Olive"), // 26
        ("#00FF00", "Lime"), // 27
        ("#98FF98", "Mint"), // 28
        ("#50C878", "Emerald"), // 29
        ("#00A86B", "Jade"), // 30
        ("#228B22", "Forest Green"), // 31
        ("#2E8B57", "Sea Green"), // 32
        ("#7FFF00", "Chartreuse"), // 33
        ("#00FF7F", "Spring Green"), // 34
        ("#7FFFD4", "Aquamarine"), // 35
        ("#007FFF", "Azure"), // 36
        ("#007BA7", "Cerulean"), // 37
        ("#0047AB", "Cobalt"), // 38
        ("#4169E1", "Royal Blue"), // 39
        ("#87CEEB", "Sky Blue"), // 40
        ("#4682B4", "Steel Blue"), // 41
        ("#6495ED", "Cornflower Blue"), // 42
        ("#1E90FF", "Dodger Blue"), // 43
        ("#191970", "Midnight Blue"), // 44
        ("#0F52BA", "Sapphire"), // 45
        ("#CCCCFF", "Periwinkle"), // 46
        ("#E6E6FA", "Lavender"), // 47
        ("#C8A2C8", "Lilac"), // 48
        ("#DDA0DD", "Plum"), // 49
        ("#DA70D6", "Orchid"), // 50
        ("#9966CC", "Amethyst"), // 51
        ("#E0B0FF", "Mauve"), // 52
        ("#614051", "Eggplant"), // 53
        ("#FF007F", "Rose"), // 54
        ("#FF69B4", "Hot Pink"), // 55
        ("#FF1493", "Deep Pink"), // 56
        ("#DE5D83", "Blush"), // 57
        ("#E30B5C", "Raspberry"), // 58
        ("#E0115F", "Ruby"), // 59
        ("#E34234", "Vermilion"), // 60
        ("#CB4154", "Brick Red"), // 61
        ("#B22222", "Firebrick"), // 62
        ("#B7410E", "Rust"), // 63
        ("#B87333", "Copper"), // 64
        ("#CD7F32", "Bronze"), // 65
        ("#FBCEB1", "Apricot"), // 66
        ("#FFE5B4", "Peach"), // 67
        ("#F28500", "Tangerine"), // 68
        ("#FF7518", "Pumpkin"), // 69
        ("#FFC30B", "Honey"), // 70
        ("#FFF700", "Lemon"), // 71
        ("#FFFF99", "Canary"), // 72
        ("#DAA520", "Goldenrod"), // 73
        ("#C2B280", "Sand"), // 74
        ("#F7E7CE", "Champagne"), // 75
        ("#EAE0C8", "Pearl"), // 76
        ("#C0C0C0", "Silver"), // 77
        ("#708090", "Slate Gray"), // 78
        ("#36454F", "Charcoal"), // 79
        ("#41424C", "Graphite"), // 80
        ("#848884", "Smoke"), // 81
        ("#FFFAFA", "Snow"), // 82
        ("#FAF0E6", "Linen"), // 83
        ("#FFF5EE", "Seashell"), // 84
        ("#F5DEB3", "Wheat"), // 85
        ("#FFE4B5", "Moccasin"), // 86
        ("#FFEFD5", "Papaya Whip"), // 87
        ("#FFE4E1", "Misty Rose"), // 88
        ("#FFF0F5", "Lavender Blush"), // 89
        ("#F0F8FF", "Alice Blue"), // 90
        ("#F8F8FF", "Ghost White"), // 91
        ("#DCDCDC", "Gainsboro"), // 92
        ("#696969", "Dim Gray"), // 93
        ("#2F4F4F", "Dark Slate Gray"), // 94
        ("#8A2BE2", "Blue Violet"), // 95
        ("#663399", "Rebecca Purple"), // 96
        ("#9932CC", "Dark Orchid"), // 97
        ("#9370DB", "Medium Purple"), // 98
        ("#98FB98", "Pale Green"), // 99
        ("#008B8B", "Dark Cyan"), // 100
        ("#8B0000", "Dark Red"), // 101
        ("#CD5C5C", "Indian Red"), // 102
        ("#F08080", "Light Coral"), // 103
        ("#E9967A", "Dark Salmon"), // 104
        ("#FFA07A", "Light Salmon"), // 105
        ("#FF4500", "Orange Red"), // 106
        ("#FF8C00", "Dark Orange"), // 107
        ("#FFFFE0", "Light Yellow"), // 108
        ("#FFFACD", "Lemon Chiffon"), // 109
        ("#FAFAD2", "Light Goldenrod Yellow"), // 110
        ("#EEE8AA", "Pale Goldenrod"), // 111
        ("#BDB76B", "Dark Khaki"), // 112
        ("#ADFF2F", "Green Yellow"), // 113
        ("#7CFC00", "Lawn Green"), // 114
        ("#32CD32", "Lime Green"), // 115
        ("#90EE90", "Light Green"), // 116
        ("#00FA9A", "Medium Spring Green"), // 117
        ("#3CB371", "Medium Sea Green"), // 118
        ("#8FBC8F", "Dark Sea Green"), // 119
        ("#20B2AA", "Light Sea Green"), // 120
        ("#00CED1", "Dark Turquoise"), // 121
        ("#48D1CC", "Medium Turquoise"), // 122
        ("#AFEEEE", "Pale Turquoise"), // 123
        ("#5F9EA0", "Cadet Blue"), // 124
        ("#B0E0E6", "Powder Blue"), // 125
        ("#B0C4DE", "Light Steel Blue"), // 126
        ("#87CEFA", "Light Sky Blue"), // 127
        ("#00BFFF", "Deep Sky Blue"), // 128
        ("#0000CD", "Medium Blue"), // 129
        ("#00008B", "Dark Blue"), // 130
        ("#7B68EE", "Medium Slate Blue"), // 131
        ("#6A5ACD", "Slate Blue"), // 132
        ("#483D8B", "Dark Slate Blue"), // 133
        ("#BA55D3", "Medium Orchid"), // 134
        ("#C71585", "Medium Violet Red"), // 135
        ("#DB7093", "Pale Violet Red"), // 136
        ("#D8BFD8", "Thistle"), // 137
        ("#BC8F8F", "Rosy Brown"), // 138
        ("#F4A460", "Sandy Brown"), // 139
        ("#CD853F", "Peru"), // 140
        ("#8B4513", "Saddle Brown"), // 141
        ("#DEB887", "Burlywood"), // 142
        ("#FFDEAD", "Navajo White"), // 143
        ("#FFE4C4", "Bisque"), // 144
        ("#FFEBCD", "Blanched Almond"), // 145
        ("#FAEBD7", "Antique White"), // 146
        ("#FFFAF0", "Floral White"), // 147
        ("#FDF5E6", "Old Lace"), // 148
        ("#FFF8DC", "Cornsilk"), // 149
        ("#F0FFF0", "Honeydew"), // 150
        ("#F5FFFA", "Mint Cream"), // 151
        ("#E0FFFF", "Light Cyan"), // 152
        ("#AFEEEE", "Pale Blue"), // 153
        ("#F5F5F5", "White Smoke"), // 154
        ("#D3D3D3", "Light Gray"), // 155
        ("#A9A9A9", "Dark Gray"), // 156
        ("#708090", "Slate"), // 157
        ("#778899", "Light Slate Gray"), // 158
        ("#343434", "Jet"), // 159
        ("#353839", "Onyx"), // 160
        ("#555D50", "Ebony"), // 161
        ("#B2BEB5", "Ash Gray"), // 162
        ("#8C92AC", "Cool Gray"), // 163
        ("#928A82", "Warm Gray"), // 164
        ("#848482", "Battleship Gray"), // 165
        ("#2A3439", "Gunmetal"), // 166
        ("#899499", "Pewter"), // 167
        ("#E5E4E2", "Platinum"), // 168
        ("#727472", "Nickel"), // 169
        ("#A5A5A5", "Aluminum"), // 170
        ("#B76E79", "Rose Gold"), // 171
        ("#B5A642", "Brass"), // 172
        ("#CFB53B", "Old Gold"), // 173
        ("#D4AF37", "Metallic Gold"), // 174
        ("#AAA9AD", "Metallic Silver"), // 175
        ("#CB6D51", "Copper Red"), // 176
        ("#CC5500", "Burnt Orange"), // 177
        ("#E97451", "Burnt Sienna"), // 178
        ("#8A3324", "Burnt Umber"), // 179
        ("#D68A59", "Raw Sienna"), // 180
        ("#826644", "Raw Umber"), // 181
        ("#704214", "Sepia"), // 182
        ("#C04000", "Mahogany"), // 183
        ("#954535", "Chestnut"), // 184
        ("#A52A2A", "Auburn"), // 185
        ("#D2691E", "Cinnamon"), // 186
        ("#6F4E37", "Coffee"), // 187
        ("#967969", "Mocha"), // 188
        ("#4E312D", "Espresso"), // 189
        ("#C68E17", "Caramel"), // 190
        ("#A67B5B", "Toffee"), // 191
        ("#B5651D", "Hazelnut"), // 192
        ("#773F1A", "Walnut"), // 193
        ("#EFDECD", "Almond"), // 194
        ("#C19A6B", "Camel"), // 195
        ("#E5AA70", "Fawn"), // 196
        ("#483C32", "Taupe"), // 197
        ("#B0A999", "Greige"), // 198
        ("#C2B280", "Ecru"), // 199
        ("#D8CDB5", "Oatmeal"), // 200
        ("#E3DAC9", "Bone"), // 201
        ("#F2E8DC", "Porcelain"), // 202
        ("#F3E5AB", "Vanilla"), // 203
        ("#FFFDD0", "Custard"), // 204
        ("#FFF1B5", "Butter"), // 205
        ("#F6E0B5", "Buttercream"), // 206
        ("#FFE135", "Banana"), // 207
        ("#FFFF31", "Daffodil"), // 208
        ("#F4CA16", "Jonquil"), // 209
        ("#EEDC82", "Flax"), // 210
        ("#FBEC5E", "Maize"), // 211
        ("#F4C430", "Saffron"), // 212
        ("#CC7722", "Ochre"), // 213
        ("#C99700", "Yellow Ochre"), // 214
        ("#E49B0F", "Gamboge"), // 215
        ("#FADA5E", "Naples Yellow"), // 216
        ("#FFD800", "School Bus Yellow"), // 217
        ("#EED202", "Safety Yellow"), // 218
        ("#FFFF33", "Electric Yellow"), // 219
        ("#CFFF04", "Neon Yellow"), // 220
        ("#B0BF1A", "Acid Green"), // 221
        ("#8DB600", "Apple Green"), // 222
        ("#4CBB17", "Kelly Green"), // 223
        ("#009E60", "Shamrock Green"), // 224
        ("#009A44", "Irish Green"), // 225
        ("#355E3B", "Hunter Green"), // 226
        ("#006A4E", "Bottle Green"), // 227
        ("#01796F", "Pine Green"), // 228
        ("#8A9A5B", "Moss Green"), // 229
        ("#9CAF88", "Sage Green"), // 230
        ("#4F7942", "Fern Green"), // 231
        ("#7CFC00", "Grass Green"), // 232
        ("#568203", "Avocado"), // 233
        ("#D1E231", "Pear"), // 234
        ("#93C572", "Pistachio"), // 235
        ("#ACE1AF", "Celadon"), // 236
        ("#0BDA51", "Malachite"), // 237
        ("#40826D", "Viridian"), // 238
        ("#43B3AE", "Verdigris"), // 239
        ("#317873", "Myrtle Green"), // 240
        ("#29AB87", "Jungle Green"), // 241
        ("#00CC99", "Caribbean Green"), // 242
        ("#00755E", "Tropical Rain Forest"), // 243
        ("#043927", "Sacramento Green"), // 244
        ("#004225", "British Racing Green"), // 245
        ("#1B4D3E", "Brunswick Green"), // 246
        ("#4B5320", "Army Green"), // 247
        ("#4B5320", "Military Green"), // 248
        ("#6B8E23", "Olive Drab"), // 249
        ("#556B2F", "Dark Olive Green"), // 250
        ("#D0F0C0", "Tea Green"), // 251
        ("#A8E4A0", "Granny Smith Apple"), // 252
        ("#98FF98", "Mint Green"), // 253
        ("#9FE2BF", "Seafoam Green"), // 254
        ("#B0E0A8", "Foam Green"), // 255
        ("#39FF14", "Neon Green"), // 256
        ("#00FF00", "Electric Green"), // 257
        ("#3FFF00", "Harlequin"), // 258
        ("#00FF40", "Erin"), // 259
        ("#66FF66", "Screamin' Green"), // 260
        ("#0D98BA", "Blue Green"), // 261
        ("#00A693", "Persian Green"), // 262
        ("#1C39BB", "Persian Blue"), // 263
        ("#32127A", "Persian Indigo"), // 264
        ("#1034A6", "Egyptian Blue"), // 265
        ("#003153", "Prussian Blue"), // 266
        ("#002147", "Oxford Blue"), // 267
        ("#00356B", "Yale Blue"), // 268
        ("#2774AE", "UCLA Blue"), // 269
        ("#5D8AA8", "Air Force Blue"), // 270
        ("#0072BB", "French Blue"), // 271
        ("#0070B8", "Spanish Blue"), // 272
        ("#73C2FB", "Maya Blue"), // 273
        ("#B9D9EB", "Columbia Blue"), // 274
        ("#89CFF0", "Baby Blue"), // 275
        ("#A1CAF1", "Baby Blue Eyes"), // 276
        ("#99FFFF", "Ice Blue"), // 277
        ("#C6E6FB", "Arctic Blue"), // 278
        ("#78B4C6", "Glacier Blue"), // 279
        ("#00CCCC", "Robin Egg Blue"), // 280
        ("#81D8D0", "Tiffany Blue"), // 281
        ("#00BFFF", "Capri"), // 282
        ("#00B7EB", "Cyan Blue"), // 283
        ("#1CA9C9", "Pacific Blue"), // 284
        ("#0095B6", "Bondi Blue"), // 285
        ("#005F69", "Peacock Blue"), // 286
        ("#4F42B5", "Ocean Blue"), // 287
        ("#042E60", "Marine Blue"), // 288
        ("#1560BD", "Denim"), // 289
        ("#3B5B92", "Denim Blue"), // 290
        ("#5D6D7E", "Stone Blue"), // 291
        ("#6699CC", "Blue Gray"), // 292
        ("#2A52BE", "Cerulean Blue"), // 293
        ("#120A8F", "Ultramarine"), // 294
        ("#4166F5", "Ultramarine Blue"), // 295
        ("#002FA7", "Klein Blue"), // 296
        ("#7DF9FF", "Electric Blue"), // 297
        ("#1F51FF", "Neon Blue"), // 298
        ("#0014A8", "Zaffre"), // 299
        ("#26619C", "Lapis Lazuli"), // 300
        ("#7FC6BC", "Beryl"), // 301
        ("#3AA8C1", "Moonstone"), // 302
        ("#126180", "Blue Sapphire"), // 303
        ("#93CCEA", "Cornflower"), // 304
        ("#C9A0DC", "Wisteria"), // 305
        ("#DF73FF", "Heliotrope"), // 306
        ("#5D3FD3", "Iris"), // 307
        ("#6F2DA8", "Grape"), // 308
        ("#722F37", "Wine"), // 309
        ("#7F1734", "Claret"), // 310
        ("#730039", "Merlot"), // 311
        ("#92000A", "Sangria"), // 312
        ("#C54B8C", "Mulberry"), // 313
        ("#873260", "Boysenberry"), // 314
        ("#4D0135", "Blackberry"), // 315
        ("#2E183B", "Blackcurrant"), // 316
        ("#290916", "Raisin"), // 317
        ("#69359C", "Purple Heart"), // 318
        ("#7851A9", "Royal Purple"), // 319
        ("#630330", "Tyrian Purple"), // 320
        ("#602F6B", "Imperial Purple"), // 321
        ("#BD33A4", "Byzantine"), // 322
        ("#702963", "Byzantium"), // 323
        ("#DF00FF", "Phlox"), // 324
        ("#BF00FF", "Electric Purple"), // 325
        ("#BC13FE", "Neon Purple"), // 326
        ("#9F00FF", "Vivid Violet"), // 327
        ("#FE4EDA", "Purple Pizzazz"), // 328
        ("#8806CE", "French Violet"), // 329
        ("#967BB6", "Lavender Purple"), // 330
        ("#C4C3D0", "Lavender Gray"), // 331
        ("#CCCCFF", "Lavender Blue"), // 332
        ("#FBAED2", "Lavender Pink"), // 333
        ("#915F6D", "Mauve Taupe"), // 334
        ("#C9A9A6", "Dusty Rose"), // 335
        ("#C08081", "Old Rose"), // 336
        ("#65000B", "Rosewood"), // 337
        ("#C21E56", "Rose Red"), // 338
        ("#FF66CC", "Rose Pink"), // 339
        ("#F64A8A", "French Rose"), // 340
        ("#FE28A2", "Persian Rose"), // 341
        ("#DE3163", "Cerise"), // 342
        ("#EC3B83", "Cerise Pink"), // 343
        ("#960018", "Carmine"), // 344
        ("#C41E3A", "Cardinal"), // 345
        ("#DE3163", "Cherry"), // 346
        ("#D2042D", "Cherry Red"), // 347
        ("#FF0800", "Candy Apple Red"), // 348
        ("#FF2800", "Ferrari Red"), // 349
        ("#D40000", "Racing Red"), // 350
        ("#880808", "Blood Red"), // 351
        ("#4A0000", "Oxblood"), // 352
        ("#AA4A44", "Brick"), // 353
        ("#E2725B", "Terra Cotta"), // 354
        ("#B66A50", "Clay"), // 355
        ("#BD6C48", "Adobe"), // 356
        ("#996666", "Copper Brown"), // 357
        ("#A45A52", "Redwood"), // 358
        ("#A52A2A", "Redwood Red"), // 359
        ("#7C4848", "Tuscan Red"), // 360
        ("#C80815", "Venetian Red"), // 361
        ("#AB4B52", "English Red"), // 362
        ("#A50021", "Madder"), // 363
        ("#E32636", "Alizarin Crimson"), // 364
        ("#E30022", "Cadmium Red"), // 365
        ("#ED872D", "Cadmium Orange"), // 366
        ("#FFF600", "Cadmium Yellow"), // 367
        ("#006B3C", "Cadmium Green"), // 368
        ("#7F3E98", "Cadmium Violet"), // 369
        ("#E34234", "Vermillion"), // 370
        ("#8D0226", "Paprika"), // 371
        ("#E23D28", "Chili Red"), // 372
        ("#941100", "Cayenne"), // 373
        ("#DC343B", "Poppy Red"), // 374
        ("#B43757", "Hibiscus"), // 375
        ("#FC6C85", "Watermelon"), // 376
        ("#FC5A8D", "Strawberry"), // 377
        ("#C83F49", "Strawberry Red"), // 378
        ("#C51D34", "Raspberry Red"), // 379
        ("#9E003A", "Cranberry"), // 380
        ("#C0392B", "Pomegranate"), // 381
        ("#E52B50", "Grenadine"), // 382
        ("#FC8EAC", "Flamingo Pink"), // 383
        ("#FFC1CC", "Bubblegum Pink"), // 384
        ("#F4C2C2", "Baby Pink"), // 385
        ("#FFBCD9", "Cotton Candy"), // 386
        ("#FFA6C9", "Carnation Pink"), // 387
        ("#F4C2C2", "Tea Rose"), // 388
        ("#EFBBCC", "Cameo Pink"), // 389
        ("#E3BC9A", "Nude"), // 390
        ("#FFDAB9", "Peach Puff"), // 391
        ("#FEBAAD", "Melon"), // 392
        ("#FFA62F", "Cantaloupe"), // 393
        ("#FFC324", "Mango"), // 394
        ("#FF8243", "Mango Tango"), // 395
        ("#FFEF00", "Papaya"), // 396
        ("#EC5800", "Persimmon"), // 397
        ("#FE6F5E", "Bittersweet"), // 398
        ("#FF4040", "Coral Red"), // 399
        ("#F88379", "Coral Pink"), // 400
        ("#FD5E53", "Sunset Orange"), // 401
        ("#FF9966", "Atomic Tangerine"), // 402
        ("#FF4F00", "International Orange"), // 403
        ("#FF6700", "Safety Orange"), // 404
        ("#FF7518", "Pumpkin Orange"), // 405
        ("#ED9121", "Carrot Orange"), // 406
        ("#FBCEB1", "Apricot Orange"), // 407
        ("#FFCC99", "Peach Orange"), // 408
        ("#FFB347", "Pastel Orange"), // 409
        ("#FDFD96", "Pastel Yellow"), // 410
        ("#77DD77", "Pastel Green"), // 411
        ("#AEC6CF", "Pastel Blue"), // 412
        ("#B39EB5", "Pastel Purple"), // 413
        ("#FFD1DC", "Pastel Pink"), // 414
        ("#FF6961", "Pastel Red"), // 415
        ("#836953", "Pastel Brown"), // 416
        ("#CFCFC4", "Pastel Gray"), // 417
        ("#F5A9B8", "Soft Pink"), // 418
        ("#A3C1DA", "Soft Blue"), // 419
        ("#A8D5BA", "Soft Green"), // 420
        ("#C3B1E1", "Soft Purple"), // 421
        ("#F6B6C8", "Powder Pink"), // 422
        ("#B39EB5", "Powder Purple"), // 423
        ("#5A86AD", "Dusty Blue"), // 424
        ("#8A9A5B", "Dusty Green"), // 425
        ("#825F87", "Dusty Purple"), // 426
        ("#D58A94", "Dusty Pink"), // 427
        ("#5B7C99", "Muted Blue"), // 428
        ("#6B8E6B", "Muted Green"), // 429
        ("#766980", "Muted Purple"), // 430
        ("#A45A52", "Muted Red"), // 431
        ("#D4C26A", "Muted Yellow"), // 432
        ("#C97A40", "Muted Orange"), // 433
        ("#FDF4E3", "Warm White"), // 434
        ("#F4F8FF", "Cool White"), // 435
        ("#FAF9F6", "Off White"), // 436
        ("#F0EAD6", "Eggshell"), // 437
        ("#EDEAE0", "Alabaster"), // 438
        ("#F5F5F0", "Chalk White"), // 439
        ("#F7F5F0", "Paper White"), // 440
        ("#C5C6D0", "Cloud"), // 441
        ("#B7B7B7", "Cloud Gray"), // 442
        ("#B6B6B4", "Dove Gray"), // 443
        ("#928E85", "Stone Gray"), // 444
        ("#858A7D", "Cement Gray"), // 445
        ("#71797E", "Steel Gray"), // 446
        ("#52595D", "Iron Gray"), // 447
        ("#36454F", "Charcoal Gray"), // 448
        ("#474A51", "Graphite Gray"), // 449
        ("#383E42", "Anthracite"), // 450
        ("#3B3C36", "Black Olive"), // 451
        ("#1A1110", "Licorice"), // 452
        ("#191970", "Midnight"), // 453
        ("#141414", "Raven"), // 454
        ("#0B0B0B", "Ink Black"), // 455
        ("#2B2B2B", "Coal"), // 456
        ("#1C1C1C", "Soot"), // 457
        ("#717486", "Storm Gray"), // 458
        ("#4F666A", "Storm Blue"), // 459
        ("#4D4D4D", "Thunder Gray"), // 460
        ("#D6D7D2", "Fog"), // 461
        ("#C4D1D9", "Mist"), // 462
        ("#D6FFFA", "Ice"), // 463
        ("#E1F5FE", "Frost"), // 464
        ("#B3E5FC", "Glacier"), // 465
        ("#E3F2FD", "Arctic"), // 466
        ("#4CB7A5", "Lagoon"), // 467
        ("#2EC4B6", "Aqua Marine"), // 468
        ("#006994", "Sea Blue"), // 469
        ("#005374", "Deep Sea Blue"), // 470
        ("#1C6EA4", "Mediterranean Blue"), // 471
        ("#4E6E81", "Aegean Blue"), // 472
        ("#279D9F", "Baltic Blue"), // 473
        ("#1AC1DD", "Caribbean Blue"), // 474
        ("#008C95", "Lagoon Blue"), // 475
        ("#00B8D4", "Pool Blue"), // 476
        ("#00FFFF", "Aqua Blue"), // 477
        ("#12E193", "Aqua Green"), // 478
        ("#53B0AE", "Blue Turquoise"), // 479
        ("#00A693", "Green Turquoise"), // 480
        ("#00A6A6", "Deep Turquoise"), // 481
        ("#08E8DE", "Bright Turquoise"), // 482
        ("#00FFEF", "Electric Turquoise"), // 483
        ("#00FFFF", "Neon Cyan"), // 484
        ("#00E5FF", "Bright Cyan"), // 485
        ("#0096FF", "Bright Blue"), // 486
        ("#66FF00", "Bright Green"), // 487
        ("#87FF2A", "Bright Lime"), // 488
        ("#FFFF00", "Bright Yellow"), // 489
        ("#FFAC1C", "Bright Orange"), // 490
        ("#EE4B2B", "Bright Red"), // 491
        ("#FF007F", "Bright Pink"), // 492
        ("#BF40BF", "Bright Purple"), // 493
        ("#F70D1A", "Vivid Red"), // 494
        ("#FF5F00", "Vivid Orange"), // 495
        ("#FFE302", "Vivid Yellow"), // 496
        ("#47E42A", "Vivid Green"), // 497
        ("#1520A6", "Vivid Blue"), // 498
        ("#9F00C5", "Vivid Purple"), // 499
        ("#FF1493", "Vivid Pink"), // 500
    ]
}
