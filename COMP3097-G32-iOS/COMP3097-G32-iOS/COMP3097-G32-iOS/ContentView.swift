//
//  ContentView.swift
//  COMP3097-G32-iOS
//
//  Updated: Added PhotosPicker (camera roll permission), SwiftData database,
//           and full History Detail View showing every saved item.
//

import SwiftUI
import Combine
import PhotosUI
import SwiftData
import Photos

// MARK: - SWIFTDATA MODELS

@Model
class DBCategory {
    var id: String
    var name: String
    var red: Double
    var green: Double
    var blue: Double
    var taxRate: Double
    
    init(id: String = UUID().uuidString,
         name: String, red: Double, green: Double, blue: Double, taxRate: Double) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.taxRate = taxRate
    }
}

@Model
class DBProduct {
    var id: String
    var name: String
    var categoryId: String
    var price: Double
    var quantity: Int
    var completed: Bool
    var imageName: String?        // asset catalog name (built-in)
    var imageData: Data?          // user-picked photo from camera roll
    
    // Which list does this belong to? nil = current active list
    var listId: String?
    
    init(id: String = UUID().uuidString,
         name: String, categoryId: String,
         price: Double, quantity: Int,
         completed: Bool = false,
         imageName: String? = nil,
         imageData: Data? = nil,
         listId: String? = nil) {
        self.id = id
        self.name = name
        self.categoryId = categoryId
        self.price = price
        self.quantity = quantity
        self.completed = completed
        self.imageName = imageName
        self.imageData = imageData
        self.listId = listId
    }
}

@Model
class DBShoppingList {
    var id: String
    var date: Date
    var total: Double
    var tax: Double
    // Items are stored as separate DBProduct rows with listId == self.id
    
    init(id: String = UUID().uuidString, date: Date, total: Double, tax: Double) {
        self.id = id
        self.date = date
        self.total = total
        self.tax = tax
    }
}

// MARK: - PLAIN STRUCTS (used inside the UI only)

struct Category: Identifiable, Hashable {
    var id: String
    var name: String
    var red: Double
    var green: Double
    var blue: Double
    var taxRate: Double
}

struct Product: Identifiable {
    var id: String
    var name: String
    var categoryId: String
    var price: Double
    var quantity: Int
    var completed: Bool
    var imageName: String?
    var imageData: Data?
}

struct ShoppingList: Identifiable {
    var id: String
    var date: Date
    var items: [Product]
    var total: Double
    var tax: Double
}

// MARK: - VIEW MODEL

@MainActor
class ShoppingStore: ObservableObject {
    @Published var categories: [Category] = []
    @Published var currentItems: [Product] = []
    @Published var history: [ShoppingList] = []
    
    // Injected SwiftData context
    var modelContext: ModelContext?
    
    func configure(with context: ModelContext) {
        self.modelContext = context
        loadFromDatabase()
        if categories.isEmpty { seedDefaultCategories() }
    }
    
    // MARK: Actions
    
    func addItem(name: String, price: Double, quantity: Int,
                 categoryId: String, imageData: Data?) {
        let assetName = imageData == nil ? imageNameForProduct(named: name) : nil
        let p = Product(id: UUID().uuidString, name: name,
                        categoryId: categoryId, price: price,
                        quantity: quantity, completed: false,
                        imageName: assetName, imageData: imageData)
        currentItems.append(p)
        persistCurrentItems()
    }
    
    func toggleItem(_ id: String) {
        if let i = currentItems.firstIndex(where: { $0.id == id }) {
            currentItems[i].completed.toggle()
            persistCurrentItems()
        }
    }
    
    func deleteItem(at offsets: IndexSet, in categoryId: String) {
        let catItems = currentItems.filter { $0.categoryId == categoryId }
        let toDelete = offsets.map { catItems[$0] }
        currentItems.removeAll { item in toDelete.contains(where: { $0.id == item.id }) }
        persistCurrentItems()
    }
    
    func addCategory(name: String, tax: Double, red: Double, green: Double, blue: Double) {
        let cat = Category(id: UUID().uuidString, name: name,
                           red: red, green: green, blue: blue, taxRate: tax)
        categories.append(cat)
        persistCategories()
    }
    
    func finishList() {
        guard !currentItems.isEmpty, let ctx = modelContext else { return }
        
        let subtotal = currentItems.reduce(0.0) { $0 + ($1.price * Double($1.quantity)) }
        var taxTotal = 0.0
        for item in currentItems {
            if let cat = categories.first(where: { $0.id == item.categoryId }) {
                taxTotal += (item.price * Double(item.quantity) * cat.taxRate) / 100.0
            }
        }
        
        let listId = UUID().uuidString
        let dbList = DBShoppingList(id: listId, date: Date(),
                                    total: subtotal + taxTotal, tax: taxTotal)
        ctx.insert(dbList)
        
        for p in currentItems {
            let dbp = DBProduct(id: p.id, name: p.name, categoryId: p.categoryId,
                                price: p.price, quantity: p.quantity,
                                completed: p.completed, imageName: p.imageName,
                                imageData: p.imageData, listId: listId)
            ctx.insert(dbp)
        }
        
        // Remove active (listId == nil) products from DB
        removeActiveProducts(in: ctx)
        
        try? ctx.save()
        
        let list = ShoppingList(id: listId, date: dbList.date,
                                items: currentItems,
                                total: dbList.total, tax: dbList.tax)
        history.insert(list, at: 0)
        currentItems.removeAll()
    }
    
    func deleteHistory(at offsets: IndexSet) {
        guard let ctx = modelContext else { return }
        let toDelete = offsets.map { history[$0] }
        history.remove(atOffsets: offsets)
        for list in toDelete {
            deleteListFromDB(list.id, ctx: ctx)
        }
        try? ctx.save()
    }
    
    func clearHistory() {
        guard let ctx = modelContext else { return }
        for list in history { deleteListFromDB(list.id, ctx: ctx) }
        history.removeAll()
        try? ctx.save()
    }
    
    // MARK: Persistence helpers
    
    private func loadFromDatabase() {
        guard let ctx = modelContext else { return }
        
        // Categories
        if let dbCats = try? ctx.fetch(FetchDescriptor<DBCategory>()) {
            categories = dbCats.map {
                Category(id: $0.id, name: $0.name,
                         red: $0.red, green: $0.green, blue: $0.blue,
                         taxRate: $0.taxRate)
            }
        }
        
        // Current items (listId == nil)
        if let dbItems = try? ctx.fetch(FetchDescriptor<DBProduct>()) {
            currentItems = dbItems.filter { $0.listId == nil }.map { productFromDB($0) }
        }
        
        // History lists
        var listDesc = FetchDescriptor<DBShoppingList>()
        listDesc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        let allProducts = (try? ctx.fetch(FetchDescriptor<DBProduct>())) ?? []
        if let dbLists = try? ctx.fetch(listDesc) {
            history = dbLists.map { dbList in
                let dbItems = allProducts.filter { $0.listId == dbList.id }
                return ShoppingList(id: dbList.id, date: dbList.date,
                                    items: dbItems.map { productFromDB($0) },
                                    total: dbList.total, tax: dbList.tax)
            }
        }
    }
    
    private func persistCurrentItems() {
        guard let ctx = modelContext else { return }
        removeActiveProducts(in: ctx)
        for p in currentItems {
            let dbp = DBProduct(id: p.id, name: p.name, categoryId: p.categoryId,
                                price: p.price, quantity: p.quantity,
                                completed: p.completed, imageName: p.imageName,
                                imageData: p.imageData, listId: nil)
            ctx.insert(dbp)
        }
        try? ctx.save()
    }
    
    private func persistCategories() {
        guard let ctx = modelContext else { return }
        // Delete old, rewrite all
        if let old = try? ctx.fetch(FetchDescriptor<DBCategory>()) {
            old.forEach { ctx.delete($0) }
        }
        for c in categories {
            ctx.insert(DBCategory(id: c.id, name: c.name,
                                  red: c.red, green: c.green, blue: c.blue,
                                  taxRate: c.taxRate))
        }
        try? ctx.save()
    }
    
    private func removeActiveProducts(in ctx: ModelContext) {
        if let existing = try? ctx.fetch(FetchDescriptor<DBProduct>()) {
            existing.filter { $0.listId == nil }.forEach { ctx.delete($0) }
        }
    }
    
    private func deleteListFromDB(_ listId: String, ctx: ModelContext) {
        if let items = try? ctx.fetch(FetchDescriptor<DBProduct>()) {
            items.filter { $0.listId == listId }.forEach { ctx.delete($0) }
        }
        if let lists = try? ctx.fetch(FetchDescriptor<DBShoppingList>()) {
            lists.filter { $0.id == listId }.forEach { ctx.delete($0) }
        }
    }
    
    private func seedDefaultCategories() {
        categories = [
            Category(id: UUID().uuidString, name: "Food",     red: 0.5, green: 0.0, blue: 0.5, taxRate: 0.0),
            Category(id: UUID().uuidString, name: "Medication",red: 0.0, green: 0.0, blue: 1.0, taxRate: 0.0),
            Category(id: UUID().uuidString, name: "Cleaning", red: 0.0, green: 1.0, blue: 0.0, taxRate: 8.875),
            Category(id: UUID().uuidString, name: "Other",    red: 0.5, green: 0.5, blue: 0.5, taxRate: 8.875)
        ]
        persistCategories()
    }
    
    private func productFromDB(_ d: DBProduct) -> Product {
        Product(id: d.id, name: d.name, categoryId: d.categoryId,
                price: d.price, quantity: d.quantity, completed: d.completed,
                imageName: d.imageName, imageData: d.imageData)
    }
    
    // MARK: Helpers
    
    func getColor(category: Category) -> Color {
        Color(red: category.red, green: category.green, blue: category.blue)
    }
    
    func imageNameForProduct(named productName: String) -> String {
        let lower = productName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("milk")   { return "milk" }
        if lower.contains("egg")    { return "eggs" }
        if lower.contains("bread")  { return "bread" }
        if lower.contains("celery") { return "celery" }
        if lower.contains("apple")  { return "apple" }
        if lower.contains("banana") { return "banana" }
        if lower.contains("cheese") { return "cheese" }
        if lower.contains("carrot") { return "carrot" }
        return "default_product"
    }
}

// MARK: - PRODUCT IMAGE VIEW (handles both asset and custom photo)

struct ProductImageView: View {
    let imageName: String?
    let imageData: Data?
    let size: CGFloat
    
    var body: some View {
        Group {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(imageName ?? "default_product")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2)
            .stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - MAIN APP VIEW

struct ContentView: View {
    @StateObject var store = ShoppingStore()
    @Environment(\.modelContext) private var modelContext
    @State private var showingAddSheet = false
    @State private var showSplash = true
    @State private var showPermissionAlert = false
    
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.white
        appearance.stackedLayoutAppearance.selected.iconColor = .black
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.black]
        appearance.stackedLayoutAppearance.normal.iconColor = .darkGray
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.darkGray]
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) { UITabBar.appearance().scrollEdgeAppearance = appearance }
    }
    
    var body: some View {
        ZStack {
            TabView {
                // 1. LIST TAB
                NavigationView {
                    ZStack(alignment: .bottomTrailing) {
                        List {
                            ForEach(store.categories) { category in
                                let items = store.currentItems.filter { $0.categoryId == category.id }
                                if !items.isEmpty {
                                    Section(header: CategoryHeader(category: category, items: items, store: store)) {
                                        ForEach(items) { item in
                                            ItemRow(item: item, store: store)
                                        }
                                        .onDelete { store.deleteItem(at: $0, in: category.id) }
                                    }
                                }
                            }
                        }
                        .listStyle(InsetGroupedListStyle())
                        .navigationTitle("Shopping List")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Finish") { store.finishList() }
                                    .disabled(store.currentItems.isEmpty)
                            }
                        }
                        
                        Button(action: { showingAddSheet = true }) {
                            Image(systemName: "plus")
                                .font(.title.weight(.semibold))
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Circle())
                                .shadow(radius: 4, x: 0, y: 4)
                        }
                        .padding()
                    }
                }
                .tabItem { Label("List", systemImage: "list.bullet") }
                
                // 2. RECEIPT TAB
                ReceiptView(store: store)
                    .tabItem { Label("Receipt", systemImage: "doc.text") }
                
                // 3. HISTORY TAB
                NavigationView {
                    List {
                        ForEach(store.history) { list in
                            NavigationLink(destination: HistoryDetailView(list: list, store: store)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.date, style: .date)
                                        .font(.headline)
                                    Text("\(list.items.count) item\(list.items.count == 1 ? "" : "s") · Total: $\(String(format: "%.2f", list.total))")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { store.deleteHistory(at: $0) }
                    }
                    .navigationTitle("History")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Clear All") { store.clearHistory() }
                                .foregroundColor(.red)
                        }
                    }
                }
                .tabItem { Label("History", systemImage: "clock") }
            }
            
            if showSplash {
                SplashView().transition(.opacity)
            }
        }
        .onAppear {
            store.configure(with: modelContext)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showSplash = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    if status == .notDetermined {
                        showPermissionAlert = true
                    }
                }
            }
        }
        .alert("Allow Photo Access", isPresented: $showPermissionAlert) {
            Button("Allow") {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
            }
            Button("Don't Allow", role: .cancel) { }
        } message: {
            Text("Shopping List would like access to your photo library so you can add photos to your items.")
        }
        .sheet(isPresented: $showingAddSheet) {
            AddItemView(store: store, isPresented: $showingAddSheet)
        }
    }
}

// MARK: - HISTORY DETAIL VIEW

struct HistoryDetailView: View {
    let list: ShoppingList
    @ObservedObject var store: ShoppingStore
    
    var groupedItems: [(Category, [Product])] {
        store.categories.compactMap { cat in
            let items = list.items.filter { $0.categoryId == cat.id }
            return items.isEmpty ? nil : (cat, items)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Receipt header
                VStack {
                    Text("RECEIPT")
                        .font(.largeTitle).fontDesign(.monospaced).fontWeight(.black)
                        .foregroundColor(.white)
                    Text(list.date, style: .date)
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black)
                
                VStack(spacing: 16) {
                    if list.items.isEmpty {
                        Text("No items in this list").italic().foregroundColor(.gray)
                    } else {
                        // Items grouped by category
                        ForEach(groupedItems, id: \.0.id) { (cat, items) in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(cat.name.uppercased())
                                    .font(.caption).fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(store.getColor(category: cat))
                                    .cornerRadius(6)
                                    .padding(.bottom, 6)
                                
                                ForEach(items) { item in
                                    HStack(spacing: 10) {
                                        ProductImageView(imageName: item.imageName,
                                                         imageData: item.imageData, size: 36)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.system(size: 14)).fontDesign(.monospaced)
                                            Text("\(item.quantity) × $\(String(format: "%.2f", item.price))")
                                                .font(.caption).foregroundColor(.gray)
                                        }
                                        Spacer()
                                        Text("$\(String(format: "%.2f", item.price * Double(item.quantity)))")
                                            .font(.system(size: 14)).fontDesign(.monospaced).bold()
                                        
                                        if item.completed {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green).font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    Divider()
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        
                        Divider().background(Color.black).padding(.vertical, 4)
                        
                        // Totals
                        HStack {
                            Text("Subtotal").fontDesign(.monospaced)
                            Spacer()
                            Text("$\(String(format: "%.2f", list.total - list.tax))").fontDesign(.monospaced)
                        }
                        HStack {
                            Text("Tax").font(.caption).foregroundColor(.gray)
                            Spacer()
                            Text("$\(String(format: "%.2f", list.tax))").font(.caption).foregroundColor(.gray)
                        }
                        Divider().background(Color.black)
                        HStack {
                            Text("TOTAL").bold().fontDesign(.monospaced)
                            Spacer()
                            Text("$\(String(format: "%.2f", list.total))").bold().fontDesign(.monospaced)
                        }
                        .font(.title3)
                        
                        // Barcode decoration
                        HStack(spacing: 2) {
                            ForEach(0..<20, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.black)
                                    .frame(width: CGFloat.random(in: 2...6), height: 40)
                            }
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(20)
                .background(Color.white)
            }
            .clipShape(ReceiptEdge())
            .shadow(radius: 5)
            .padding()
        }
        .background(Color(UIColor.systemGray6).ignoresSafeArea())
        .navigationTitle("Past List")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - SUBVIEWS

struct CategoryHeader: View {
    let category: Category
    let items: [Product]
    let store: ShoppingStore
    
    var total: Double { items.reduce(0) { $0 + ($1.price * Double($1.quantity)) } }
    
    var body: some View {
        HStack {
            Text(category.name).font(.headline).foregroundColor(.white)
            Spacer()
            Text("$\(String(format: "%.2f", total))").font(.subheadline).bold().foregroundColor(.white.opacity(0.9))
        }
        .padding()
        .background(LinearGradient(
            colors: [store.getColor(category: category), store.getColor(category: category).opacity(0.7)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

struct ItemRow: View {
    let item: Product
    let store: ShoppingStore
    
    var body: some View {
        HStack(spacing: 12) {
            ProductImageView(imageName: item.imageName, imageData: item.imageData, size: 50)
            
            Button(action: { store.toggleItem(item.id) }) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.completed ? .green : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            
            VStack(alignment: .leading) {
                Text(item.name)
                    .strikethrough(item.completed)
                    .foregroundColor(item.completed ? .gray : .primary)
                Text("\(item.quantity) × $\(String(format: "%.2f", item.price))")
                    .font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Text("$\(String(format: "%.2f", item.price * Double(item.quantity)))").bold()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ADD ITEM VIEW (with PhotosPicker)

struct AddItemView: View {
    @ObservedObject var store: ShoppingStore
    @Binding var isPresented: Bool
    
    @State private var name = ""
    @State private var price = ""
    @State private var quantity = "1"
    @State private var selectedCategory = ""
    
    // Photo picker state
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var customImageData: Data? = nil
    
    // New group state
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var newGroupTax = ""
    @State private var red: Double = 0.5
    @State private var green: Double = 0.5
    @State private var blue: Double = 0.5
    
    var previewAssetName: String {
        store.imageNameForProduct(named: name.isEmpty ? "default" : name)
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Image preview + photo picker
                Section(header: Text("Item Photo")) {
                    HStack {
                        Spacer()
                        ProductImageView(imageName: customImageData == nil ? previewAssetName : nil,
                                         imageData: customImageData, size: 90)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    
                    // PhotosPicker — requests photo library access automatically
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(customImageData == nil ? "Choose from Camera Roll" : "Change Photo",
                              systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                customImageData = data
                            }
                        }
                    }
                    
                    if customImageData != nil {
                        Button(role: .destructive) {
                            customImageData = nil
                            selectedPhotoItem = nil
                        } label: {
                            Label("Remove Custom Photo", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                
                Section(header: Text("Item Details")) {
                    TextField("Name (e.g. Milk)", text: $name)
                    TextField("Price", text: $price).keyboardType(.decimalPad)
                    Stepper("Quantity: \(quantity)", value: Binding(
                        get: { Int(quantity) ?? 1 },
                        set: { quantity = String($0) }
                    ), in: 1...99)
                }
                
                Section(header: Text("Category")) {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(store.categories) { cat in
                            Text(cat.name).tag(cat.id)
                        }
                    }
                    Button("Add New Group") { showingNewGroup = true }
                }
                
                if showingNewGroup {
                    Section(header: Text("New Group Details")) {
                        TextField("Group Name", text: $newGroupName)
                        TextField("Tax Rate %", text: $newGroupTax).keyboardType(.decimalPad)
                    }
                    Section(header: Text("Pick Color")) {
                        Color(red: red, green: green, blue: blue)
                            .frame(height: 50).cornerRadius(10)
                        Slider(value: $red,   in: 0...1) { Text("Red") }
                        Slider(value: $green, in: 0...1) { Text("Green") }
                        Slider(value: $blue,  in: 0...1) { Text("Blue") }
                    }
                    Button("Save Group") {
                        if let tax = Double(newGroupTax), !newGroupName.isEmpty {
                            store.addCategory(name: newGroupName, tax: tax,
                                              red: red, green: green, blue: blue)
                            showingNewGroup = false
                            newGroupName = ""
                            newGroupTax = ""
                        }
                    }
                }
                
                Button("Add Item") {
                    if let p = Double(price), let q = Int(quantity), !name.isEmpty {
                        let catId = selectedCategory.isEmpty ? store.categories.first?.id ?? "" : selectedCategory
                        store.addItem(name: name, price: p, quantity: q,
                                      categoryId: catId, imageData: customImageData)
                        isPresented = false
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(name.isEmpty || price.isEmpty)
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .onAppear {
                if selectedCategory.isEmpty {
                    selectedCategory = store.categories.first?.id ?? ""
                }
            }
        }
    }
}

// MARK: - RECEIPT TAB VIEW

struct ReceiptEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tw: CGFloat = 10, th: CGFloat = 10
        let count = Int(rect.width / tw)
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - th))
        for i in 0..<count {
            let x = rect.width - CGFloat(i) * tw
            path.addLine(to: CGPoint(x: x - tw/2, y: rect.height))
            path.addLine(to: CGPoint(x: x - tw,   y: rect.height - th))
        }
        path.addLine(to: CGPoint(x: 0, y: rect.height - th))
        path.closeSubpath()
        return path
    }
}

struct ReceiptView: View {
    @ObservedObject var store: ShoppingStore
    
    var subtotal: Double { store.currentItems.reduce(0) { $0 + ($1.price * Double($1.quantity)) } }
    var taxes: [(String, Double)] {
        store.categories.compactMap { cat in
            let items = store.currentItems.filter { $0.categoryId == cat.id }
            if items.isEmpty { return nil }
            let total = items.reduce(0.0) { $0 + ($1.price * Double($1.quantity)) }
            return (cat.name, total * cat.taxRate / 100)
        }
    }
    var totalTax: Double { taxes.reduce(0) { $0 + $1.1 } }
    var grandTotal: Double { subtotal + totalTax }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGray6).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack {
                    Text("RECEIPT").font(.largeTitle).fontDesign(.monospaced).fontWeight(.black).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity).padding().background(Color.black)
                
                VStack(spacing: 16) {
                    Text(Date(), style: .date).font(.caption).foregroundColor(.gray).padding(.bottom)
                    
                    if store.currentItems.isEmpty {
                        Text("No items yet").italic().foregroundColor(.gray)
                    } else {
                        ForEach(store.currentItems) { item in
                            HStack(spacing: 10) {
                                ProductImageView(imageName: item.imageName, imageData: item.imageData, size: 28)
                                Text("\(item.quantity) × \(item.name)")
                                Spacer()
                                Text("$\(String(format: "%.2f", item.price * Double(item.quantity)))")
                            }
                            .fontDesign(.monospaced).font(.system(size: 14))
                        }
                        Divider().background(Color.black)
                        HStack { Text("Subtotal"); Spacer(); Text("$\(String(format: "%.2f", subtotal))") }.fontDesign(.monospaced)
                        ForEach(taxes, id: \.0) { tax in
                            HStack {
                                Text("Tax (\(tax.0))").font(.caption).foregroundColor(.gray)
                                Spacer()
                                Text("$\(String(format: "%.2f", tax.1))").font(.caption).foregroundColor(.gray)
                            }
                        }
                        Divider().background(Color.black)
                        HStack { Text("TOTAL").bold(); Spacer(); Text("$\(String(format: "%.2f", grandTotal))").bold() }
                            .font(.title3).fontDesign(.monospaced)
                    }
                    
                    HStack(spacing: 2) {
                        ForEach(0..<20, id: \.self) { _ in
                            Rectangle().fill(Color.black).frame(width: CGFloat.random(in: 2...6), height: 40)
                        }
                    }
                    .padding(.top, 20).opacity(0.8)
                }
                .padding(24).background(Color.white)
            }
            .clipShape(ReceiptEdge()).shadow(radius: 5).padding()
        }
    }
}

// MARK: - SPLASH VIEW

struct SplashView: View {
    @State private var scale = 0.8
    var body: some View {
        ZStack {
            Color.blue.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 80)).foregroundColor(.white).scaleEffect(scale)
                Text("Shopping List App").font(.largeTitle).fontWeight(.bold).foregroundColor(.white)
                VStack(spacing: 4) {
                    Text("Sabannah De-Gale"); Text("101487100"); Text("Section: 50488")
                    Text("")
                    Text("Vu Anh Quan (Bill) Tran"); Text("101513060"); Text("Section: 50488")
                    Text("")
                    Text("Omoruyi Oredia"); Text("101496942"); Text("Section: 54621")
                }
                .font(.caption).foregroundColor(.white.opacity(0.9)).multilineTextAlignment(.center)
                ProgressView().tint(.white).padding(.top, 10)
            }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.5)) { scale = 1.0 }
        }
    }
}

