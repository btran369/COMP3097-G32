//
//  ContentView.swift
//  COMP3097-G32-iOS
//
//  Created by Vu.Quan.Tran on 2026-02-12.
//

import SwiftUI
import Combine

// MARK: - MODELS
struct Category: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var colorName: String // "purple", "blue", etc.
    var taxRate: Double
}

struct Product: Identifiable, Codable {
    var id: String
    var name: String
    var categoryId: String
    var price: Double
    var quantity: Int
    var completed: Bool
}

struct ShoppingList: Identifiable, Codable {
    var id: String
    var date: Date
    var items: [Product]
    var total: Double
    var tax: Double
}

// MARK: - VIEW MODEL (The "Store")
class ShoppingStore: ObservableObject {
    @Published var categories: [Category] = []
    @Published var currentItems: [Product] = []
    @Published var history: [ShoppingList] = []
    
    init() {
        loadData()
        if categories.isEmpty {
            // Defaults
            categories = [
                Category(id: UUID().uuidString, name: "Food", colorName: "purple", taxRate: 0.0),
                Category(id: UUID().uuidString, name: "Medication", colorName: "blue", taxRate: 0.0),
                Category(id: UUID().uuidString, name: "Cleaning", colorName: "green", taxRate: 8.875),
                Category(id: UUID().uuidString, name: "Other", colorName: "gray", taxRate: 8.875)
            ]
        }
    }
    
    // Actions
    func addItem(name: String, price: Double, quantity: Int, categoryId: String) {
        let newItem = Product(id: UUID().uuidString, name: name, categoryId: categoryId, price: price, quantity: quantity, completed: false)
        currentItems.append(newItem)
        saveData()
    }
    
    func toggleItem(_ id: String) {
        if let index = currentItems.firstIndex(where: { $0.id == id }) {
            currentItems[index].completed.toggle()
            saveData()
        }
    }
    
    func deleteItem(at offsets: IndexSet, in categoryId: String) {
        // Complex delete logic because of grouped view
        let categoryItems = currentItems.filter { $0.categoryId == categoryId }
        let itemsToDelete = offsets.map { categoryItems[$0] }
        currentItems.removeAll { item in itemsToDelete.contains(where: { $0.id == item.id }) }
        saveData()
    }
    
    func addCategory(name: String, tax: Double, color: String) {
        let newCat = Category(id: UUID().uuidString, name: name, colorName: color, taxRate: tax)
        categories.append(newCat)
        saveData()
    }
    
    func finishList() {
        guard !currentItems.isEmpty else { return }
        
        let subtotal = currentItems.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
        var taxTotal: Double = 0
        
        for item in currentItems {
            if let cat = categories.first(where: { $0.id == item.categoryId }) {
                taxTotal += (item.price * Double(item.quantity) * cat.taxRate) / 100.0
            }
        }
        
        let list = ShoppingList(id: UUID().uuidString, date: Date(), items: currentItems, total: subtotal + taxTotal, tax: taxTotal)
        history.insert(list, at: 0)
        currentItems.removeAll()
        saveData()
    }
    
    func clearHistory() {
        history.removeAll()
        saveData()
    }
    
    // Persistence
    func saveData() {
        if let encoded = try? JSONEncoder().encode(currentItems) { UserDefaults.standard.set(encoded, forKey: "currentItems") }
        if let encoded = try? JSONEncoder().encode(categories) { UserDefaults.standard.set(encoded, forKey: "categories") }
        if let encoded = try? JSONEncoder().encode(history) { UserDefaults.standard.set(encoded, forKey: "history") }
    }
    
    func loadData() {
        if let data = UserDefaults.standard.data(forKey: "currentItems"), let decoded = try? JSONDecoder().decode([Product].self, from: data) { currentItems = decoded }
        if let data = UserDefaults.standard.data(forKey: "categories"), let decoded = try? JSONDecoder().decode([Category].self, from: data) { categories = decoded }
        if let data = UserDefaults.standard.data(forKey: "history"), let decoded = try? JSONDecoder().decode([ShoppingList].self, from: data) { history = decoded }
    }
    
    // Helpers
    func getColor(name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }
}

// MARK: - MAIN APP VIEW
struct ContentView: View {
    @StateObject var store = ShoppingStore()
    @State private var showingAddSheet = false
    
    var body: some View {
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
                                    .onDelete { indexSet in
                                        store.deleteItem(at: indexSet, in: category.id)
                                    }
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
                    
                    // Floating Action Button
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
            .tabItem {
                Label("List", systemImage: "list.bullet")
            }
            
            // 2. RECEIPT TAB
            ReceiptView(store: store)
                .tabItem {
                    Label("Receipt", systemImage: "doc.text")
                }
            
            // 3. HISTORY TAB
            NavigationView {
                List {
                    ForEach(store.history) { list in
                        VStack(alignment: .leading) {
                            Text(list.date, style: .date)
                                .font(.headline)
                            Text("Total: $\(String(format: "%.2f", list.total))")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                    .onDelete { indexSet in
                        store.history.remove(atOffsets: indexSet)
                        store.saveData()
                    }
                }
                .navigationTitle("History")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear") { store.clearHistory() }
                    }
                }
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddItemView(store: store, isPresented: $showingAddSheet)
        }
    }
}

// MARK: - SUBVIEWS

struct CategoryHeader: View {
    let category: Category
    let items: [Product]
    let store: ShoppingStore
    
    var total: Double {
        items.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
    }
    
    var body: some View {
        HStack {
            Text(category.name)
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Text("$\(String(format: "%.2f", total))")
                .font(.subheadline)
                .bold()
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, -4)
        .listRowInsets(EdgeInsets())
        .background(store.getColor(name: category.colorName))
    }
}

struct ItemRow: View {
    let item: Product
    let store: ShoppingStore
    
    var body: some View {
        HStack {
            Button(action: { store.toggleItem(item.id) }) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.completed ? .green : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            
            VStack(alignment: .leading) {
                Text(item.name)
                    .strikethrough(item.completed)
                    .foregroundColor(item.completed ? .gray : .primary)
                Text("\(item.quantity) x $\(String(format: "%.2f", item.price))")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Text("$\(String(format: "%.2f", item.price * Double(item.quantity)))")
                .bold()
        }
    }
}

struct AddItemView: View {
    @ObservedObject var store: ShoppingStore
    @Binding var isPresented: Bool
    
    @State private var name = ""
    @State private var price = ""
    @State private var quantity = "1"
    @State private var selectedCategory = ""
    
    // For new category
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var newGroupTax = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Item Details")) {
                    TextField("Name (e.g. Milk)", text: $name)
                    TextField("Price", text: $price)
                        .keyboardType(.decimalPad)
                    Stepper("Quantity: \(quantity)", value: Binding(
                        get: { Int(quantity) ?? 1 },
                        set: { quantity = String($0) }
                    ))
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
                        TextField("Tax Rate %", text: $newGroupTax)
                            .keyboardType(.decimalPad)
                        Button("Save Group") {
                            if let tax = Double(newGroupTax), !newGroupName.isEmpty {
                                store.addCategory(name: newGroupName, tax: tax, color: "orange")
                                showingNewGroup = false
                                newGroupName = ""
                                newGroupTax = ""
                            }
                        }
                    }
                }
                
                Button("Add Item") {
                    if let p = Double(price), let q = Int(quantity), !name.isEmpty {
                        // Default to first category if none selected
                        let catId = selectedCategory.isEmpty ? store.categories.first?.id ?? "" : selectedCategory
                        store.addItem(name: name, price: p, quantity: q, categoryId: catId)
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

// Custom Shape for Receipt ZigZag
struct ReceiptEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let toothWidth: CGFloat = 10
        let toothHeight: CGFloat = 10
        let count = Int(rect.width / toothWidth)
        
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - toothHeight))
        
        for i in 0..<count {
            let x = rect.width - (CGFloat(i) * toothWidth)
            path.addLine(to: CGPoint(x: x - (toothWidth / 2), y: rect.height))
            path.addLine(to: CGPoint(x: x - toothWidth, y: rect.height - toothHeight))
        }
        
        path.addLine(to: CGPoint(x: 0, y: rect.height - toothHeight))
        path.closeSubpath()
        return path
    }
}

struct ReceiptView: View {
    @ObservedObject var store: ShoppingStore
    
    var subtotal: Double {
        store.currentItems.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
    }
    
    var taxes: [(String, Double)] {
        store.categories.compactMap { cat -> (String, Double)? in
            let items = store.currentItems.filter { $0.categoryId == cat.id }
            if items.isEmpty { return nil }
            let catTotal = items.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
            return (cat.name, (catTotal * cat.taxRate) / 100)
        }
    }
    
    var totalTax: Double { taxes.reduce(0) { $0 + $1.1 } }
    var grandTotal: Double { subtotal + totalTax }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGray6).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                VStack {
                    Text("RECEIPT")
                        .font(.largeTitle)
                        .fontDesign(.monospaced)
                        .fontWeight(.black)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black)
                
                // Body
                VStack(spacing: 16) {
                    Text(Date(), style: .date)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.bottom)
                    
                    if store.currentItems.isEmpty {
                        Text("No items yet").italic().foregroundColor(.gray)
                    } else {
                        ForEach(store.currentItems) { item in
                            HStack {
                                Text("\(item.quantity) x \(item.name)")
                                Spacer()
                                Text("$\(String(format: "%.2f", item.price * Double(item.quantity)))")
                            }
                            .fontDesign(.monospaced)
                            .font(.system(size: 14))
                        }
                        
                        Divider().background(Color.black)
                        
                        HStack {
                            Text("Subtotal")
                            Spacer()
                            Text("$\(String(format: "%.2f", subtotal))")
                        }
                        .fontDesign(.monospaced)
                        
                        ForEach(taxes, id: \.0) { tax in
                            HStack {
                                Text("Tax (\(tax.0))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text("$\(String(format: "%.2f", tax.1))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        Divider().background(Color.black)
                        
                        HStack {
                            Text("TOTAL")
                                .bold()
                            Spacer()
                            Text("$\(String(format: "%.2f", grandTotal))")
                                .bold()
                        }
                        .font(.title3)
                        .fontDesign(.monospaced)
                    }
                    
                    // Barcode placeholder
                    HStack(spacing: 2) {
                        ForEach(0..<20) { _ in
                            Rectangle()
                                .fill(Color.black)
                                .frame(width: CGFloat.random(in: 2...6), height: 40)
                        }
                    }
                    .padding(.top, 20)
                    .opacity(0.8)
                }
                .padding(24)
                .background(Color.white)
            }
            .clipShape(ReceiptEdge())
            .shadow(radius: 5)
            .padding()
        }
    }
}
